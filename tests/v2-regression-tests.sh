#!/bin/bash

# openapi v1 下线改造回归测试

declare TEST_ACTION='' TEST_ACTION_DONE=''
test_act(){
  [ ! -z "$TEST_ACTION" ] && [ -z "$TEST_ACTION_DONE" ] && test_ok
  TEST_ACTION="$1" && shift && TEST_ACTION_DONE='' && echo "[ACTION - $TEST_ACTION] $*">&2
}
test_ok(){
  echo "[OK - $TEST_ACTION] $*">&2 && TEST_ACTION_DONE='Y' && return 0
}
test_err(){
  echo "[ERR - $TEST_ACTION] $*">&2; return 1
}

trap 'test_err "TEST FAIL !!!" || true && exit 1' EXIT
set -e -o pipefail

test_act "install role files" && rm -f /usr/bin/npc && \
  (INSTALLED_ROLE="/etc/ansible/roles/xiaopal.npc_setup" && \
    cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && \
    cp -rv * "$INSTALLED_ROLE/" && \
    ansible-playbook "$INSTALLED_ROLE/tests/noop.yml")

test_act "init ssh key" && npc playbook -<<\EOF
---
- hosts: localhost
  gather_facts: no
  roles:
    - role: xiaopal.npc_setup
      npc_config:
        ssh_key: 
          name: v2-regression-tests-tmp1
EOF


test_act "create vpc instances + volumes" && npc playbook -<<\EOF
---
- hosts: localhost
  gather_facts: no
  roles:
    - role: xiaopal.npc_setup
      npc_config:
        ssh_key: 
          name: v2-regression-tests
      npc_volumes:
        - name: test-hd-{1,2}
          zone: cn-east-1b
          capacity: 10G
      npc_instances:
        - name: test-vm
          zone: cn-east-1b
          instance_type: {series: 2, type: 2, cpu: 4, memory: 8G}
          instance_image: Debian 8.6
          vpc: defaultVPCNetwork
          vpc_subnet: default
          vpc_security_group: default
          vpc_inet: yes
          vpc_inet_capacity: 10m
          volumes:
            - name: test-hd-1
            - test-hd-2
          present: yes
  tasks:
    - debug: msg={{npc}}
EOF

test_act "save images" && npc playbook -<<\EOF
---
- hosts: localhost
  gather_facts: no
  roles:
    - role: xiaopal.npc_setup
      npc_instance_images:
        - name: test-image-1
          from_instance: test-vm
EOF

test_act "create instance from private image" && npc playbook -<<\EOF
---
- hosts: localhost
  gather_facts: no
  roles:
    - role: xiaopal.npc_setup
      npc_config:
        ssh_key: 
          name: v2-regression-tests
      npc_instances:
        - name: test-vm-pri-image
          zone: cn-east-1b
          instance_type: {series: 2, type: 2, cpu: 4, memory: 8G}
          instance_image: test-image-1
          vpc: defaultVPCNetwork
          vpc_subnet: default
          vpc_security_group: default
          vpc_inet: yes
          vpc_inet_capacity: 10m
EOF

test_act "delete images" && npc playbook -<<\EOF
---
- hosts: localhost
  gather_facts: no
  roles:
    - role: xiaopal.npc_setup
      npc_instance_images:
        - name: test-image-1
          present: no
      npc_instances:
        - name: test-vm-pri-image
          zone: cn-east-1b
          present: no
EOF

test_act "mount volumes" && npc playbook -<<\EOF
---
- hosts: localhost
  gather_facts: no
  roles:
    - role: xiaopal.npc_setup
      npc_volumes:
        - name: test-hd-3
          zone: cn-east-1b
          capacity: 10G
      npc_instances:
        - name: test-vm
          zone: cn-east-1b
          volumes:
            - name: test-hd-3
          present: yes
  tasks:
    - debug: msg={{npc}}
EOF

test_act "unmount volumes" && npc playbook -<<\EOF
---
- hosts: localhost
  gather_facts: no
  roles:
    - role: xiaopal.npc_setup
      npc_instances:
        - name: test-vm
          zone: cn-east-1b
          volumes:
            - name: test-hd-1
              present: no
          present: yes
  tasks:
    - debug: msg={{npc}}
EOF


test_act "destroy instances + volumes" && npc playbook -<<\EOF
---
- hosts: localhost
  gather_facts: no
  roles:
    - role: xiaopal.npc_setup
      npc_volumes:
        - name: test-hd-{1,2,3}
          zone: cn-east-1b
          present: no
      npc_instances:
        - name: test-vm
          zone: cn-east-1b
          present: no
  tasks:
    - debug: msg={{npc}}
EOF

test_act "create more volumes" && npc playbook -<<\EOF
---
- hosts: localhost
  gather_facts: no
  roles:
    - role: xiaopal.npc_setup
      npc_volumes:
        - name: test-hd-ext-{1..10}
          zone: cn-east-1b
          type: ssd
          capacity: 10G
  tasks:
    - debug: msg={{npc}}
EOF

test_act "delete more volumes" && npc playbook -<<\EOF
---
- hosts: localhost
  gather_facts: no
  roles:
    - role: xiaopal.npc_setup
      npc_volumes:
        - name: test-hd-ext-{1..10}
          zone: cn-east-1b
          present: no
  tasks:
    - debug: msg={{npc}}
EOF


trap - EXIT && test_ok "ALL TESTS SUCCESS"