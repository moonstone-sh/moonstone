source tests/scripts/install_synthetic.sh
WORKDIR="/tmp/moonstone-contract-project-discovery-2"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}/parent/child/grandchild"
cd "${WORKDIR}/parent"

moon init . --name discovery-test --no-git
moon use lua@5.4 --no-sync

cd child/grandchild
list_output=$(moon list)
run_output=$(moon run missing 2>&1 || true)
moon add inspect@3.1.3 --no-sync
