#!/usr/bin/env bash

RED='\033[0;31m'
NC='\033[0m'
TIME=5
PREVIEW_TIME=30

function test_manila {
    declare -a share1=("/etc/ceph")
    declare -a share2=("/etc/ceph")
    declare -a share3= "/etc/manila")
    alias openstack="oc rsh openstackclient openstack"

    echo "---------------------"
    echo "MANILA PREVIEW"
    echo "---------------------"
    printf "* Secret:  ${RED}ceph-client-conf${NC}\n"
        printf "  * ceph.conf: ${RED}/etc/ceph${NC}\n"
        printf "  * ceph.client.openstack.keyring: ${RED}/etc/ceph${NC}\n"
    printf "* Services: ${RED}share1${NC} ${RED}share2${NC}\n"
        printf "\n"
    printf "* Secret:  ${RED}netapp${NC}\n"
        printf "  * 04-secret.conf: ${RED}/etc/manila/manila.conf.d/04-secret.conf${NC}\n"
    printf "* Services: ${RED}share3${NC}\n"
    echo "---------------------"
    sleep $PREVIEW_TIME

    pod=$(oc get pods | awk '/share1/ {print $1}')
    if [ -n "$pod" ]; then
    for m in "${share1[@]}"; do
        printf "Share1 instance: %s ${RED}$pod${NC}:${RED}$m${NC}\n"
        oc exec -it "$pod" -- ls "$m"
        echo "----------------------"
    done
    fi

    sleep $TIME
    pod=$(oc get pods | awk '/share2/ {print $1}')
    if [ -n "$pod" ]; then
    for m in "${share2[@]}"; do
        printf "Share2 instance: %s ${RED}$pod${NC}:${RED}$m${NC}\n"
        oc exec -it "$pod" -- ls "$m"
        echo "----------------------"
    done
    fi

    sleep $TIME
    sec=$(oc get secret | awk '/netapp/ {print $1}')
    if [ -n "$sec" ]; then
        oc describe secret $sec
        echo "----------------------"
    fi

    sleep $TIME
    manila_services=$(openstack share service list)
    if [ -n "$manila_services" ]; then
        echo "OpenStack Manila Services ($ openstack share service list):"
        echo $manila_services
    fi

    sleep $TIME
    pools=$(openstack share pool list)
    if [ -n "$pools" ]; then
        echo "The storage pools known to OpenStack Manila "
        echo "($ openstack share pool list):"
        echo $pools
    fi

    # Creating share types
    sleep $TIME
    if [ -n "$pools" ]; then
        echo "----------------------"
        echo "Let's create a default share type that will direct provisioning to Ceph"
        openstack share type create default False \
                  --extra-specs snapshot_support=True  \
                  create_share_from_snapshot_support=True vendor_name=Ceph
        echo "Let's create a share type that we'll use with NetApp"
        openstack share type create bigboxtype False \
                  --extra-specs snapshot_support=True  \
                  revert_to_snapshot_support=True
                  create_share_from_snapshot_support=True
    fi

    # Creating and displaying shares and their export paths
    sleep $TIME
    if [ -n "$pools" ]; then
        echo "----------------------"
        echo "Let's create an Native CephFS share: "
        openstack share create cephfs 10 --name cephfs-share
        echo "Let's create an NFS share: "
        openstack share create nfs 10 --name nfs-share
        echo "And a CIFS share (will end up on NetApp)"
        openstack share create cifs 10 --name cifs-share --share-type bigboxtype
        echo "----------------------"
        sleep $TIME
        echo "Export locations of these shares"
        openstack share export location list cephfs-share
        openstack share export location list nfs-share
        openstack share export location list cifs-share

        nfs_export=$(openstack share export location list nfs-share -c Path -f value)
        cephfs_export=$(openstack share export location list cephfs-share -c Path -f value)
    fi

    # allowing access and mounting shares
    # we have two clients, baremetal nodes with IP addresses 10.10.10.40 and
    # 10.10.10.50; we'll allow access and mount the NFS share in 10.10.10.40
    # and the CEPHFS share in 10.10.10.50
    openstack share access create nfs-share ip 10.10.10.40
    openstack share access create cephfs-share cephx alice

    sleep $TIME
    openstack share access list nfs-share
    openstack share access list cephfs-share

    cephx_secret=$(openstack share access list cephfs-share -c "Access Secret" -f value)

    # mounting the shares
    echo "Mounting the NFS share on client1 with IP address 10.10.10.40"
    ssh root@10.10.10.40 mount -t nfs $nfs_export /mnt
    ssh root@10.10.10.40 touch /mnt/test1 /mnt/test2 /mnt/test3

    echo "Testing client restrictions, 10.10.10.50 doesn't have access"
    ssh root@10.10.10.50 mount -t nfs $nfs_export /mnt

    echo "Permitting 10.10.10.50 to access the share:"
    openstack share access create nfs-share ip 10.10.10.50
    sleep $TIME

    echo "Re-attempting mount, 10.10.10.50 now has access"
    ssh root@10.10.10.50 mount -t nfs $nfs_export /mnt
    ssh root@10.10.10.50 ls -l /mnt

    sleep $TIME

    echo "Mounting the CephFS share with native CEPHFS"
    ssh root@10.10.10.50 umount /mnt
    ssh root@10.10.10.50 mount -t cephfs $cephfs_export /mnt -o name=alice,secret=$cephx_secret

    ssh root@10.10.10.50 touch /mnt/test5 /mnt/test6 /mnt/test7
    ssh root@10.10.10.50 ls -l /mnt

}

test_manila
