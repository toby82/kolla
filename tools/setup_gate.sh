#!/bin/bash

set -o xtrace
set -o errexit

# Just for mandre :)
if [[ ! -f /etc/sudoers.d/jenkins ]]; then
    echo "jenkins ALL=(:docker) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/jenkins
fi

# TODO(SamYaple): Remove this after https://review.openstack.org/#/c/294871/
# NOTE(SamYaple): Temporarily fix RAX gate suffering from glean config issue
if [[ $(hostname) =~ "rax-ord" ]]; then
    sudo ifdown eth1
    sleep 1
    sudo ifup eth1
fi

function setup_config {
    # generate the config
    tox -e genconfig
    # Copy configs
    sudo cp -a etc/kolla /etc/
    # Generate passwords
    sudo tools/generate_passwords.py

    # Use Infra provided pypi
    echo "RUN echo $(base64 -w0 /etc/pip.conf) | base64 -d > /etc/pip.conf" | sudo tee /etc/kolla/header
    sed -i 's|^#include_header.*|include_header = /etc/kolla/header|' /etc/kolla/kolla-build.conf

    if [[ "${DISTRO}" == "Debian" ]]; then
        # Infra does not sign thier mirrors so we ignore gpg signing in the gate
        echo "RUN echo 'APT::Get::AllowUnauthenticated \"true\";' > /etc/apt/apt.conf" | sudo tee -a /etc/kolla/header

        # Optimize the repos to take advantage of the Infra provided mirrors for Ubuntu
        sed -i 's|^#apt_sources_list.*|apt_sources_list = /etc/kolla/sources.list|' /etc/kolla/kolla-build.conf
        sudo cp /etc/apt/sources.list /etc/kolla/sources.list
        # Append non-infra provided repos to list
        cat << EOF | sudo tee -a /etc/kolla/sources.list
deb http://ubuntu-cloud.archive.canonical.com/ubuntu trusty-updates/mitaka main
deb http://nyc2.mirrors.digitalocean.com/mariadb/repo/10.0/ubuntu trusty main
deb http://repo.percona.com/apt trusty main
deb http://download.ceph.com/debian-hammer/ trusty main
deb http://packages.elastic.co/elasticsearch/2.x/debian stable main
deb http://packages.elastic.co/kibana/4.4/debian stable main
EOF
    fi
}

function detect_distro {
    DISTRO=$(ansible all -i "localhost," -msetup -clocal | awk -F\" '/ansible_os_family/ {print $4}')
}

function setup_ssh {
    # Generate a new keypair that Ansible will use
    ssh-keygen -f /home/jenkins/.ssh/kolla -N ''
    cat /home/jenkins/.ssh/kolla.pub >> /home/jenkins/.ssh/authorized_keys

    # Push the public key around to all of the nodes
    for ip in $(cat /etc/nodepool/sub_nodes_private); do
        scp /home/jenkins/.ssh/kolla.pub ${ip}:/home/jenkins/.ssh/authorized_keys
        # TODO(SamYaple): Remove this root key pushing once Kolla doesn't
        # require root anymore.
        ssh ${ip} -i /home/jenkins/.ssh/kolla 'sudo mkdir -p /root/.ssh; sudo cp /home/jenkins/.ssh/* /root/.ssh/'
    done

    # From now on use the new IdentityFile for connecting to other hosts
    echo "IdentityFile /home/jenkins/.ssh/kolla" >> /home/jenkins/.ssh/config
}

function setup_inventory {
    local counter=0

    if [[ "${DISTRO}" == "Debian" ]]; then
        ANSIBLE_CONNECTION_TYPE=ssh
    else
        ANSIBLE_CONNECTION_TYPE=local
    fi

    echo -e "127.0.0.1\tlocalhost" > /tmp/hosts
    for ip in $(cat /etc/nodepool/{node_private,sub_nodes_private}); do
        : $((counter++))
        echo -e "${ip}\tnode${counter} $(ssh ${ip} hostname)" >> /tmp/hosts
        echo "node${counter} ansible_connection=${ANSIBLE_CONNECTION_TYPE}" >> ${RAW_INVENTORY}
    done

    sudo chown root: /tmp/hosts
    sudo chmod 644 /tmp/hosts
    sudo mv /tmp/hosts /etc/hosts
}

function setup_ansible {
    RAW_INVENTORY=/tmp/kolla/raw_inventory
    mkdir /tmp/kolla

    # TODO(SamYaple): Move to virtualenv
    sudo -H pip install -U "ansible<2" "docker-py>=1.6.0" "python-openstackclient" "python-neutronclient"
    detect_distro

    setup_inventory

    # Record the running state of the environment as seen by the setup module
    ansible all -i ${RAW_INVENTORY} -m setup > /tmp/logs/ansible/initial-setup
}

function setup_node {
    ansible-playbook -i ${RAW_INVENTORY} tools/setup_nodes.yml
}

function setup_logging {
    # This directory is the directory that is copied with the devstack-logs
    # publisher. It must exist at /home/jenkins/workspace/<job-name>/logs
    mkdir logs

    # For ease of access we symlink that logs directory to a known path
    ln -s $(pwd)/logs /tmp/logs
    mkdir -p /tmp/logs/{ansible,build,kolla}
}

setup_logging
tools/dump_info.sh
setup_ssh
setup_ansible
setup_node
setup_config
