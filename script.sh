#!/bin/bash

# --- Configuración de rutas ---
BASE_DIR=$(dirname "$(realpath "$0")")
CONFIG_FILE="${BASE_DIR}/Config.sh"
LOG_FILE="${BASE_DIR}/deploy.log"
# Fail Fast
set -o errexit -o nounset -o pipefail
# --- Cargar configuración ---
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
        git clone "$repo_url" "$target_dir"
        if [ $? -ne 0 ]; then
            echo "Error al clonar $target_dir"
            exit 1
        fi
    else
        echo "El directorio $target_dir ya existe, actualizando..."
        cd "$target_dir" || exit
        git pull
        cd - || exit
    fi
}

# llamada a la funcion (pasando los parametros) para clonar ambos repositorios
clone_repo "$STATIC_REPO" "static-website"
clone_repo "$MANIFESTS_REPO" "manifiestos-kubernetes"

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

# Montar el directorio estático con manejo robusto
echo "Montando el directorio estático..."

# Detener montajes previos si existen
if pgrep -f "minikube mount.*$MOUNT_POINT" >/dev/null; then
    echo "Deteniendo montaje previo..."
    pkill -f "minikube mount.*$MOUNT_POINT" && sleep 2
fi


minikube mount $STATIC_PATH:/mnt/website -p $MINIKUBE_PROFILE >/dev/null 2>&1 &
MOUNT_PID=$!
sleep 10

# Eliminar PV si ya existe
if kubectl get pv 0311at-pv &>/dev/null; then
    echo "Eliminando PV existente..."
    kubectl delete pv 0311at-pv
fi

# 5. Aplicar los manifiestos Kubernetes
echo "Aplicando manifiestos YAML..."
kubectl apply -f "$MANIFESTS_PATH/namespace.yml"
kubectl apply -f "$MANIFESTS_PATH/configmap.yml"
kubectl apply -f "$MANIFESTS_PATH/persistenceVolume.yml"
kubectl apply -f "$MANIFESTS_PATH/persistenceVolumeClaim.yml"
kubectl apply -f "$MANIFESTS_PATH/deployment.yml"
kubectl apply -f "$MANIFESTS_PATH/service.yml"

# Función para esperar a que los pods estén listos
wait_for_pods() {
    local namespace=$1
    local selector=$2
    local timeout=${3:-120}  # Valor por defecto: 120 segundos
    local interval=${4:-5}   # Valor por defecto: 5 segundos
    
    echo "Esperando a que los pods con selector '$selector' estén listos..."
    local start_time=$(date +%s)
    
    while true; do
        if kubectl get pods -n "$namespace" -l "$selector" 2>/dev/null | grep -q "Running"; then
            echo "Todos los pods están corriendo"
            return 0
        fi
        
        local current_time=$(date +%s)
        if (( current_time - start_time > timeout )); then
            echo "Timeout: Los pods no están listos después de $timeout segundos" >&2
            kubectl get pods -n "$namespace"
            return 1
        fi
        
        sleep "$interval"
    done
}

# Llamar a la función de espera
wait_for_pods "$NAMESPACE" "app=webapp" 420 5 || exit 1

# 6. Exponer el servicio
echo "Exponiendo el servicio..."
minikube service service-0311 -p "$MINIKUBE_PROFILE" -n "$NAMESPACE"

# Mensaje final
echo -e "\n¡Entorno listo!"
echo "El sitio está montado desde: $STATIC_PATH"
echo "Manifiestos aplicados desde: $MANIFESTS_PATH"
echo "Para detener el montaje ejecuta: kill $MOUNT_PID"

# Mantener el script abierto (opcional)
read -rp "Presiona Enter para salir (el montaje seguirá activo)..."
