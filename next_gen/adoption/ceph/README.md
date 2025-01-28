# (DEV) - Externalize Ceph cluster

## Ansible - SSH bastion / jump host

The current approach is not based on `inventory` variables, but it rather uses
a `ssh_config` approach to define everything ssh related.
The proxy configuration for all SSH connections are realized through the config
generated into a specific `~/.ssh/config_ansible` file, that looks like the
following:

```
Host *hypervisor*
  Hostname %h.<fqdn>
  IdentityFile <path/to/hypervisor/key>
  StrictHostkeyChecking no
  User <hypervisor_user>

Host undercloud-0
   ProxyJump <hypervisor>
   StrictHostkeyChecking no
   User stack
   IdentityFile <path/to/undercloud/key>

# Update the id_rsa key before running ansible:
# scp -F ~/.ssh/config_ansible undercloud-0:/home/stack/.ssh/id_rsa <path/to/undercloud/key>

Host controller-*.ctlplane
   StrictHostkeyChecking no
   ProxyJump undercloud-0
   User tripleo-admin
   IdentityFile <path/to/undercloud/key>

Host cephstorage-*
   StrictHostkeyChecking no
   ProxyJump undercloud-0
   User tripleo-admin
   IdentityFile <path/to/undercloud/key>
```

- Update the undercloud key mentioned in the previous snippet:

```
scp -F ~/.ssh/config_ansible undercloud-0:/home/stack/.ssh/id_rsa ~/devnull/keys
```

Ansible automatically includes the SSH options defined in the user provided
SSH config, so it picks the above settings without defining any variable in the
inventory.

- Update the ansible.cfg to reference the `.ssh/config_ansible` file:

```
callback_whitelist = profile_json,profile_tasks
roles_path = ./roles
module_utils=./plugins/module_utils
library=./plugins/modules
..
..

[ssh_connection]
pipelining = True
ssh_args = -F $HOME/.ssh/config_ansible -o ControlMaster=auto -o ControlPersist=1200
```

- Update the inventory to reference hosts as described in the ssh config file.
  An inventory should look like the following:

```
[hyperviror]
<hypervisor_hostname || ip>

[undercloud]
undercloud-0

[mon]
controller-0.ctlplane
controller-1.ctlplane
controller-2.ctlplane

[osds]
controller-2.ctlplane
cephstorage-0.ctlplane
cephstorage-1.ctlplane

[overcloud]
controller-0.ctlplane
controller-1.ctlplane
controller-2.ctlplane
cephstorage-0.ctlplane
cephstorage-1.ctlplane
```

- Check the nodes in the inventory are reachable:

```
ansible -i <inventory> -m ping all
```

## Interact with Ceph

- Build a ceph client:

```
ceph_dir="/etc/ceph"
ceph_dir="/home/tripleo-admin/ceph_client"
alias ceph="sudo podman run --rm --net=host --ipc=host --volume $ceph_dir:/etc/ceph:z --entrypoint ceph undercloud-0.ctlplane.example.local:8787/ceph/ceph:6 --fsid <FSID> -c /etc/ceph/ceph.conf -k /etc/ceph/ceph.client.admin.keyring "

watch ${BASH_ALIASES[ceph]} -s
```
