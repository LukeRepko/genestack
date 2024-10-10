#!/usr/bin/env bash
set -e
KUSTOMIZE_DIR=${1:-$GENESTACK_KUSTOMIZE_ARG}
pushd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null
    test -d "${KUSTOMIZE_DIR}"/../base || mkdir "${KUSTOMIZE_DIR}"/../base
    cat <&0 > "${KUSTOMIZE_DIR}"/../base/all.yaml
    kubectl kustomize --reorder='none' "${KUSTOMIZE_DIR}"
popd &>/dev/null
