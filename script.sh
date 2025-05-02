#!/bin/bash

# --- Configuración de rutas ---
BASE_DIR=$(dirname "$(realpath "$0")")
CONFIG_FILE="${BASE_DIR}/Config.sh"
LOG_FILE="${BASE_DIR}/deploy.log"
# Fail Fast
set -o errexit -o nounset -o pipefail

# Carga de configuración con validación
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: Archivo de configuración no encontrado: $CONFIG_FILE" >&2
  exit 1
fi
source "$CONFIG_FILE"

# Redireccionar toda la salida al log
exec > >(tee -a "$LOG_FILE") 2>&1

# --- Función para mostrar configuración ---
show_config() {
    echo -e "\n${YELLOW}=== Revisar Configuración Actual ===${NC}"
    echo -e "Perfil Minikube: ${GREEN}$MINIKUBE_PROFILE${NC}"
    echo -e "Namespace:      ${GREEN}$NAMESPACE${NC}"
    echo -e "Repositorios:"
    echo -e "  - Estático:   ${GREEN}$STATIC_REPO${NC}"
    echo -e "  - Manifiestos: ${GREEN}$MANIFESTS_REPO${NC}"
    echo -e "Ruta de montaje: ${GREEN}$MOUNT_POINT${NC}"
    echo -e "Manifiestos a aplicar:"
    for manifest in "${K8S_MANIFESTS[@]}"; do
        echo -e "  - ${GREEN}$manifest${NC}"
    done
}
# Función para verificar dependencias
check_dependencies() {
    local missing=0

    # Verificar Git
    if ! command -v git &> /dev/null; then
        echo -e "${RED}ERROR: Git no está instalado${NC}"
        echo -e "Instala Git con:"
        echo -e "  Ubuntu/Debian: sudo apt install git"
        echo -e "  CentOS/RHEL: sudo yum install git"
        echo -e "  MacOS: brew install git"
        missing=$((missing+1))
    else
        echo -e "${GREEN}Git está instalado${NC} ($(git --version))"
    fi

    # Verificar Minikube
    if ! command -v minikube &> /dev/null; then
        echo -e "${RED}ERROR: Minikube no está instalado${NC}"
        echo -e "Instala Minikube siguiendo:"
        echo -e "  https://minikube.sigs.k8s.io/docs/start/"
        missing=$((missing+1))
    else
        echo -e "${GREEN}Minikube está instalado${NC} ($(minikube version --short))"
    fi

    # Verificar kubectl
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}ERROR: kubectl no está instalado${NC}"
        echo -e "Instala kubectl siguiendo:"
        echo -e "  https://kubernetes.io/docs/tasks/tools/"
        missing=$((missing+1))
    else
        echo -e "${GREEN}kubectl está instalado${NC} ($(kubectl version --client --short))"
    fi

    # Verificar Docker
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}ADVERTENCIA: Docker no está instalado${NC}"
        echo -e "Minikube puede necesitar Docker como driver"
        echo -e "Considera instalarlo:"
        echo -e "  https://docs.docker.com/get-docker/"
    else
        echo -e "${GREEN}Docker está instalado${NC} ($(docker --version))"
    fi

    if [ $missing -gt 0 ]; then
        echo -e "\n${RED}Error: Faltan $missing dependencias esenciales${NC}"
        exit 1
    fi
}
# Función para clonar repositorios

clone_repo() {
    local repo_url=$1
    local target_dir=$2
    
    if [ ! -d "$target_dir" ]; then
        echo "Clonando $target_dir..."
        git clone "$repo_url" "$target_dir" || { echo "Error al clonar $target_dir"; exit 1; }
    else
        echo "El directorio $target_dir ya existe, actualizando..."
        cd "$target_dir" || exit
        git pull || { echo "Error al actualizar $target_dir"; exit 1; }
        cd - || exit
    fi
}

# función para aplicar manifiestos
apply_manifests() {
    local manifests_dir="$1"
    
    echo "Eliminando deployment anterior para forzar actualización..."
    kubectl delete deployment webapp-deployment -n "$NAMESPACE" --wait=false --ignore-not-found
    sleep 5
    
    echo "Aplicando manifiestos Kubernetes..."
    minikube ssh -p "$MINIKUBE_PROFILE" -- "ls -la /mnt/website"
    kubectl apply -f "$manifests_dir/" -n "$NAMESPACE"
    
    echo "Verificando versión del deployment..."
    kubectl get deployment webapp-deployment -n "$NAMESPACE" -o yaml | \
        grep deployment.kubernetes.io/revision
}

# Uso:
clone_repo "$STATIC_REPO" "static-website"
clone_repo "$MANIFESTS_REPO" "manifiestos-kubernetes"
apply_manifests "manifiestos-kubernetes"

# 2. Obtener rutas absolutas
STATIC_PATH=$(realpath ./static-website)
MANIFESTS_PATH=$(realpath ./manifiestos-kubernetes)
echo "Ruta del sitio estático: $STATIC_PATH"
echo "Ruta de los manifiestos: $MANIFESTS_PATH"

# 3. Verificar/Iniciar Minikube

ensure_minikube_running() {
    local profile=$1
    local addons=${2:-"metrics-server"}
    
    if ! minikube status -p "$profile" &>/dev/null; then
        echo "Perfil $profile no existe, creándolo..."
        minikube start -p "$profile" \
            --addons="$addons" \
            --driver=docker \
            --memory=1885 \
            --cpus=2
    elif ! minikube status -p "$profile" | grep -q "Running"; then
        echo "Reiniciando perfil $profile..."
        minikube stop -p "$profile"
        minikube start -p "$profile"
    else
        echo "Minikube con perfil $profile ya está corriendo"
    fi
    
    # Verificar que todos los addons están habilitados
    for addon in $(echo "$addons" | tr ',' ' '); do
        if ! minikube addons list -p "$profile" | grep -q "$addon.*enabled"; then
            minikube addons enable "$addon" -p "$profile"
        fi
    done
}

# Uso:
ensure_minikube_running "$MINIKUBE_PROFILE" "metrics-server,ingress"


#Montar el directorio estático // tiene idempotencia

echo "Configurando montaje..."

# Detener montajes previos
pkill -f "minikube mount" || true
sleep 2

# Montar con verificación robusta
echo "Montando $STATIC_PATH en $MOUNT_POINT..."
minikube mount "$STATIC_PATH:$MOUNT_POINT" -p "$MINIKUBE_PROFILE" > mount.log 2>&1 &
MOUNT_PID=$!
sleep 5  # Espera crítica para que el montaje esté activo

# Verificación exhaustiva
echo "Verificando montaje..."
if ! minikube ssh -p "$MINIKUBE_PROFILE" -- "test -d $MOUNT_POINT && ls $MOUNT_POINT | grep -q ."; then
    echo "ERROR: Montaje falló - mostrando logs:"
    cat mount.log
    minikube ssh -p "$MINIKUBE_PROFILE" -- "ls -la $(dirname $MOUNT_POINT)"
    exit 1
fi

# Eliminación robusta de PV/PVC
echo "Iniciando limpieza de recursos persistentes..."

# 1. Primero eliminar el PVC (si existe)
if kubectl get pvc -n $NAMESPACE 0311at-pvc-html &>/dev/null; then
    echo "Eliminando PVC..."
    kubectl delete pvc -n $NAMESPACE 0311at-pvc-html --wait=false --ignore-not-found
    
    # Esperar hasta 15 segundos para que se elimine
    for i in {1..15}; do
        if ! kubectl get pvc -n $NAMESPACE 0311at-pvc-html &>/dev/null; then
            break
        fi
        sleep 1
    done
    
    # Forzar eliminación si aún existe
    if kubectl get pvc -n $NAMESPACE 0311at-pvc-html &>/dev/null; then
        echo "Forzando eliminación de PVC..."
        kubectl patch pvc -n $NAMESPACE 0311at-pvc-html -p '{"metadata":{"finalizers":null}}' --type=merge
    fi
fi

# 2. Luego eliminar el PV (si existe)
if kubectl get pv 0311at-pv &>/dev/null; then
    echo "Eliminando PV..."
    kubectl delete pv 0311at-pv --wait=false --ignore-not-found
    
    # Esperar hasta 15 segundos
    for i in {1..15}; do
        if ! kubectl get pv 0311at-pv &>/dev/null; then
            break
        fi
        sleep 1
    done
    
    # Forzar eliminación si aún existe
    if kubectl get pv 0311at-pv &>/dev/null; then
        echo "Forzando eliminación de PV..."
        kubectl patch pv 0311at-pv -p '{"metadata":{"finalizers":null}}' --type=merge
    fi
fi

# Espera adicional para limpieza completa
sleep 3

# 1. Forzar recreación del directorio
minikube ssh -p "$MINIKUBE_PROFILE" -- "sudo rm -rf $MOUNT_POINT && sudo mkdir -p $MOUNT_POINT && sudo chmod 777 $MOUNT_POINT"

# 2. Copiar archivos manualmente (solución garantizada)
echo "Copiando archivos al nodo..."
minikube cp "$STATIC_PATH/" "$MOUNT_POINT"

# 3. Verificación final
echo "Contenido actual en $MOUNT_POINT:"
minikube ssh -p "$MINIKUBE_PROFILE" -- "ls -la $MOUNT_POINT"

# Mantener el script abierto (opcional)
read -rp "Presiona Enter para salir (el montaje seguirá activo)..."
# Aplicar los manifiestos Kubernetes
echo "Aplicando manifiestos YAML..."
kubectl apply -f "$MANIFESTS_PATH/namespace.yml"
kubectl apply -f "$MANIFESTS_PATH/configmap.yml"
kubectl apply -f "$MANIFESTS_PATH/persistenceVolume.yml"
kubectl apply -f "$MANIFESTS_PATH/persistenceVolumeClaim.yml"
kubectl apply -f "$MANIFESTS_PATH/deployment.yml"
kubectl apply -f "$MANIFESTS_PATH/service.yml"

echo "Esperando a que los pods estén listos..."
if ! kubectl wait --for=condition=Ready \
   --namespace "$NAMESPACE" \
   --selector=app=webapp \
   pods \
   --timeout=300s; then  # Aumenta a 5 minutos
   
   echo "ERROR: Pods no ready - mostrando diagnóstico:"
   kubectl get pods -n $NAMESPACE -o wide
   kubectl describe pods -n $NAMESPACE --selector=app=webapp
   kubectl logs -n $NAMESPACE --selector=app=webapp --all-containers
   exit 1
fi

# Exponer el servicio
echo "Exponiendo el servicio..."
minikube service service-0311 -p "$MINIKUBE_PROFILE" -n "$NAMESPACE"

# Mensaje final
echo -e "\n¡Entorno listo!"
echo "El sitio está montado desde: $STATIC_PATH"
echo "Manifiestos aplicados desde: $MANIFESTS_PATH"
echo "Para detener el montaje ejecuta: kill $MOUNT_PID"
