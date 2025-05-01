#!/bin/bash

# --- Configuración básica ---
export MINIKUBE_PROFILE="0311at"
export NAMESPACE="0311at-web"
export MOUNT_POINT="/mnt/website"

# --- Repositorios Git ---
export STATIC_REPO="https://github.com/JuliettaSh/static-website.git"
export MANIFESTS_REPO="https://github.com/JuliettaSh/NuevosManifiestos.git"

# --- Rutas locales ---
export STATIC_DIR="./static-website"
export MANIFESTS_DIR="./NuevosManifiestos"

# --- Configuración de Kubernetes ---
export K8S_MANIFESTS=(
    "namespace.yml"
    "configmap.yml"
    "persistenceVolume.yml"
    "persistenceVolumeClaim.yml"
    "deployment.yml"
    "service.yml"
)

# --- Colores para los mensajes ---
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export NC='\033[0m' 

