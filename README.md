# Proyecto Kubernetes - Despliegue de Página Web Estática
Descripción
Este proyecto implementa el despliegue de una página web estática en un clúster Kubernetes local usando Minikube. Utiliza recursos como Namespace, ConfigMap, PersistentVolume, PersistentVolumeClaim, Deployment y Service, con un enfoque en el montaje directo del contenido mediante minikube mount.

## Requisitos
* Git instalado
* Minikube (última versión)
* kubectl configurado
* Docker o otro driver compatible con Minikube
* Espacio suficiente en disco para los volúmenes persistentes
## Pasos para reproducir el entorno
## Clonar repositorios
* git clone https://github.com/JuliettaSh/NuevosManifiestos.git
* git clone https://github.com/JuliettaSh/static-website.git
## Inicializar Minikube
* minikube start -p 0311at --addons=metrics-server --mount --mount-string="/ruta/local/static-website:/mnt/website"
***
(Nota: Reemplaza /ruta/local/static-website con la ruta absoluta a tu directorio clonado.)
## Configurar montaje persistente
* minikube mount /ruta/local/static-website:/mnt/website -p 0311at
***
(Nota: Mantén este proceso ejecutándose en una terminal aparte y abre una nueva para los siguientes pasos)
## Aplicar los manifiestos
* Muevete a la carpeta donde hayas hecho el clone del repo de manifiestos con "cd"
* kubectl apply -f namespace.yml
* kubectl apply -f configmap.yml
* kubectl apply -f persistenceVolume.yml
* kubectl apply -f persistenceVolumeClaim.yml
* kubectl apply -f deployment.yml
* kubectl apply -f service.yml
## Exponer el servicio
* minikube service service-0311 -p 0311at -n 0311at-web
## Flujo de trabajo para actualizaciones
* Realiza cambios en tu directorio local static-website
* Los cambios se reflejarán automáticamente en el pod gracias al montaje persistente

# Si no tienes ganas de hacer todo eso, solo ejecuta este script en linux
descarga los sh y ejecutalos usando primero el comando para darles permiso
* chmod +x script.sh

