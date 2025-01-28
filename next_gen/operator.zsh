# /usr/bin/zsh

WORKDIR=$HOME/devnull/osp-k8s-operators/dev_operator
SRC=$HOME/devnull/osp-k8s-operators/dev_operator/lib-common
SNO_WORKDIR=$HOME/devnull/ocp
GOROOT_DIR=/usr/lib/go/src/

OPENSTACK=/usr/bin/openstack
SAMPLES=$WORKDIR/samples
CRC_BIN=/usr/local/bin/crc
CRC_TARGET=$HOME/.crc
KUBEADMIN_PWD=${KUBEADMIN_PWD:-"12345678"}
PULL_SECRET_FILE=${PULL_SECRET_FILE:-$HOME"/.ssh/pull_secret"}

function crc_setup {
    crc config set consent-telemetry no
    ${CRC_BIN} config set consent-telemetry no
    ${CRC_BIN} config set kubeadmin-password ${KUBEADMIN_PWD}
    ${CRC_BIN} config set pull-secret-file ${PULL_SECRET_FILE}
    # Executing systemctl action failed:  exit status 1: Failed to connect to bus: No such file or directory
    # https://github.com/code-ready/crc/issues/2674
    crc config set skip-check-daemon-systemd-unit true
    crc config set skip-check-daemon-systemd-sockets true
    crc config set skip-check-crc-symlink true
    crc config set cpus 10
    crc config set memory 65536
    crc config set disk-size 50
    ${CRC_BIN} setup
}

alias m='make manifests && make generate && make'
alias mt='make test GINKGO_ARGS="--output-interceptor-mode=none"'

function crc_ssh {
    ssh -i ~/.crc/machines/crc/id_ecdsa -o StrictHostKeyChecking=no core@$(shell crc ip)
}

function crc_add_disk {
    local disk="$1"
    if [[ -z "$disk" ]]; then
        echo "crc_add_disk <disk_name> <disk_size>"
        exit 1
    fi
    local disk_size=${4:-"10G"}
    qemu-img create -f raw $CRC_TARGET/$disk $disk_size
    dd if=/dev/zero of=$CRC_TARGET/vm$disk bs=1M count=1000 status=progress
    sudo virsh attach-disk crc $CRC_TARGET/$disk $disk --config --cache none

}

# An old workaround to include lib-common for not pushed changes
# This is still valid for multiple lib-common includes in go.mod
function sync_lib_common {
  sudo cp -R $SRC $GOROOT_DIR
}

function link_operator {
    local libcommon="github.com/openstack-k8s-operators/lib-common/modules/storage v0.0.0-00010101000000-000000000000"
    local OPERATOR_NAME=$1
    if [ -z "$OPERATOR_NAME" ]; then
        echo "link_operator <operator_name>"
    else
        echo "Linking operator $OPERATOR_NAME to $PWD/tmp"
        mkdir -p $PWD/tmp
        ln -s $WORKDIR/$OPERATOR_NAME  ./tmp/$OPERATOR_NAME

        # Update go.mod
        if [[ "$OPERATOR_NAME" == "lib-common" ]]; then
            sed -i $'/require/{a\tgithub.com/openstack-k8s-operators/lib-common/modules/storage v0.0.0-00010101000000-000000000000\n:a;n;ba}' go.mod
            go mod edit -replace github.com/openstack-k8s-operators/$OPERATOR_NAME/modules/storage=./tmp/$OPERATOR_NAME/modules/storage
        else
            go mod edit -replace github.com/openstack-k8s-operators/$OPERATOR_NAME/api=./tmp/$OPERATOR_NAME/api
        fi
    fi
    go mod tidy

}

function crd_del {
    for i in $WORKDIR/$OPERATOR_NAME/config/crd/bases/*; {
       oc create -f $i;
    }
}

function crd {
    ACTION="$1"
    local OPERATOR_NAME=$2
    if [ -z "$OPERATOR_NAME" ]; then
        echo "crd $ACTION <operator_name>"
    else
        # stat operator_name path first ?
        for i in $(ls $WORKDIR/$OPERATOR_NAME-operator/config/crd/bases/* | grep -v _.yaml) ; {
            oc $ACTION -f $i;
        }
    fi
}

function delete_crd {
    OPERATOR_NAME="$1"
    ACTION="delete"
    # call the crd function with the delete parameters
    crd "delete" $1
}

function create_crd {
    OPERATOR_NAME="$1"
    ACTION="create"
    # call the crd function with the create parameters
    crd "create" $1
}

function clean_pv {
    NODE_NAME=$(oc get node -o name -l node-role.kubernetes.io/worker | head -n 1)

    for i in $(oc get pv | grep -E "(Failed|Released)" | awk {'print $1'}); do
        oc patch pv $i --type='json' -p='[{"op": "remove", "path": "/spec/claimRef"}]';
    done

    # now, it's time to run a real clanup of the crc directory

    if [ -z "$NODE_NAME" ]; then
      echo "Unable to determine node name with 'oc' command."
      exit 1
    fi
    oc debug $NODE_NAME -T -- chroot /host /usr/bin/bash -c "for i in {1..6}; do echo \"deleting dir content /mnt/openstack/pv00\$i\"; rm -rf /mnt/openstack/pv00\$i/*; done"

}

function endpoint_create {
    region="regionOne"
    local service=$1
    if [ -z "$service" ]; then
        echo "build_ep <service_name>"
        return
    fi
    if [[ $service == "cinder" ]]; then
        path="v3/%(project_id)s"
        svc="cinderv3"
    fi
    for ep in admin internal public; do
        $OPENSTACK endpoint create --region $region $svc $ep "http://$service-$ep-openstack.apps-crc.testing/$path";
    done
}

function scale_operator {
    local op="$1"
    local ns="$2"
    oc scale deployment $op-operator-controller-manager --replicas=0 -n $ns
}

function scale_operators {
    for op in openstack-ansibleee manila ironic horizon openstack cinder glance placement dataplane nova neutron; do
        scale_operator $op $ns
    done
}

# TEST OPERATORS

function test_cinder {
    local type=$1
    if [ -z "$type" ]; then
        echo "test_cinder <cinder_type>"
        echo "  |-> e.g., test_cinder ceph"
        return
    fi
    cinder type-create $type
    cinder type-list
    cinder type-key $type set volume_backend_name=$type
    sleep 2
    cinder create 1 --volume-type $type --name "$type"_disk
}

function test_manila {
    openstack share list
    openstack share service list
    openstack share pool list
    # openstack share pool list --detail
    openstack share type list
    openstack share type create default false
    openstack share type list
    openstack share create cephfs 1
    openstack share list
}

function test_glance {
    OSP="/usr/local/bin/oc rsh openstackclient openstack"
    IMAGE=$SAMPLES/cirros-0.5.2-x86_64-disk.img
    "$OSP" image create --disk-format qcow2 --container-format bare --file "$IMAGE" cirros-test
    sleep 5
    "$OSP" image list
    #openstack delete cirros-test
}

function test_glance_policies {
    echo "Building projects and users"
    openstack project create --description 'project a' project-a --domain default
    openstack project create --description 'project b' project-b --domain default
    openstack user create project-a-reader --password project-a-reader
    openstack user create project-b-reader --password project-b-reader
    openstack user create project-a-member --password project-a-member
    openstack user create project-b-member --password project-b-member

    echo "Building projects and users"
    openstack role add --user project-a-member --project project-a member
    openstack role add --user project-a-reader --project project-a reader

    openstack role add --user project-b-member --project project-b member
    openstack role add --user project-b-reader --project project-b reader
}

function remove_finalizers {
    for i in $(oc get keystoneendpoint -o name); do oc patch $i --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'; done; for i in $(oc get keystoneservice -o name); do oc patch $i --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'; done
}

function delete_completed {
    NS="openstack"
    oc delete pod --field-selector=status.phase==Succeeded -n $NS
}

function build_external_ceph_crc {
    ceph_script=$1
    scp -i ~/.crc/machines/crc/id_ecdsa "$ceph_script" core@"$(crc ip)":/var/home/core
    ssh -i ~/.crc/machines/crc/id_ecdsa core@"$(crc ip)" chmod +x /var/home/core/$(basename $ceph_script)
    ssh -i ~/.crc/machines/crc/id_ecdsa core@"$(crc ip)" sh /var/home/core/$(basename $ceph_script)
}

function crc_ssh {
    ssh -i ~/.crc/machines/crc/id_ecdsa core@"$(crc ip)"
}

function checkout_pr {
    ID=$1
    BRANCHNAME="PR#$1"
    REMOTE=${REMOTE:-upstream}

    if [ -z "$1" ]; then
        echo "The PR ID must be specified"
        exit 1
    fi

    git fetch $REMOTE pull/$ID/head:$BRANCHNAME
}

function disable_webhooks {
    OPERATOR=${OPERATOR:-"openstack"}
    VERSION=${VERSION:-"v0.0.1"}
    oc patch csv $OPERATOR-operator.$VERSION --type=json -p="[{'op': 'remove', 'path': '/spec/webhookdefinitions'}]"
}


## SNO
function destroy_cluster {
    openshift-install destroy cluster --dir $SNO_WORKDIR/clusters/shiftstack
}

function attach_interface {
    local net_name="$1"
    local domain="$2"
    MAC=$(date +%s | md5sum | head -c 6 | sed -e 's/\([0-9A-Fa-f]\{2\}\)/\1:/g' -e 's/\(.*\):$/\1/' | sed -e 's/^/52:54:00:/')
    sudo virsh attach-interface --domain $domain --type network --mac ${MAC} --source $net_name --model virtio --config --live
}

function clean_pods {
    oc delete pod --field-selector=status.phase==Succeeded
}

function refresh_glance {
    oc get pods | grep -E "glance-(ext|int)" | awk '{print $1}' | xargs -n 1 oc delete pod
}

function list_pod_containers {
    local pod="$1"
    if [ -z "$pod" ]; then
        echo "list_pod_containers <pod_name>"
        exit 1
    fi
    for container in $(oc get pods "$pod" -o jsonpath='{.spec.containers[*].name}');
        do echo $container;
    done
}

function patch_csv {
    local component="$1"
    local namespace="openstack-operators"
    local image="$2"
    if [[ -z "$component" ]] || [[ -z "$image" ]]; then
        echo "patch_csv <operator> <new_container>"
        exit 1
    fi
    oc patch csv -n "$namespace" "$component"-operator.v0.0.1 --type='json' -p='[{"op":"replace", "path":"/spec/install/spec/deployments/0/spec/template/spec/containers/1/image", "value": "$image"}]'
    # EXAMPLE:
    #oc patch csv -n openstack-operators glance-operator.v0.0.1 --type='json' \
    #  -p='[{"op":"replace", "path":"/spec/install/spec/deployments/0/spec/template/spec/containers/1/image", \
    #     "value": "quay.io/fpantano/glance-operator:latest"}]'
}

function rm_marketplace {
    oc delete catalogsource --all -n openshift-marketplace
}

function kuttl_run {
    OPERATOR=$1
    NAMESPACE=${2:-openstack}
    if [[ -z "$OPERATOR" ]];  then
        echo "kuttl_run <operator_path> <namespace>"
        return
    fi

    kubectl-kuttl test --config $OPERATOR/kuttl-test.yaml \
        $OPERATOR/test/kuttl/tests/ --namespace $NAMESPACE | tee -a $HOME/kuttl.log

}
