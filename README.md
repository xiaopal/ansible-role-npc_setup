# ansible-role-npc_setup

## How to use
```
$ ansible-galaxy install xiaopal.npc_setup \
    && ansible-playbook /etc/ansible/roles/xiaopal.npc_setup/tests/noop.yml

$ declare APP_KEY=<蜂巢APP_KEY> APP_SECRET=<蜂巢APP_SECRET> \
    && cat<<EOF >playbook.yml \
    && npc playbook --tags="setup" -T 30 playbook.yml \
    && read -p 'setup finished, press [enter] to cleanup...' \
    && npc playbook --tags="cleanup" playbook.yml
---
- hosts: localhost
  gather_facts: no
  tags: setup
  vars:
    # 公共配置
    npc_config:
      app_key: $APP_KEY
      app_secret: $APP_SECRET
      # 用于 ansible 管理的 ssh key 名称，自动在蜂巢创建并下载私钥到~/.npc/ssh_key.<name>
      ssh_key: 
        name: ansible-tests
      # 默认云主机镜像名称
      default_instance_image: Debian 8.6
      # 默认云主机规格
      default_instance_type:
        cpu: 2
        memory: 4G
    # 云硬盘
    npc_volumes:
      # 定义三块云硬盘，名称分别为 hd-test-gw,hd-test-a,hd-test-b, 容量20G
      - name: hd-test-{gw,{a..b}}
        capacity: 20G
        present: true
        path: /volumes/hd1
    # 云主机
    npc_instances: 
      # 定义云主机 debian-test-gw
      - name: 'debian-test-gw'
        present: true
        # 挂载云硬盘
        volumes:
          - hd-test-gw
        # 绑定外网IP: 取值可以是IP地址或any/new
        # any 绑定任意可用的外网IP，如果没有则新建IP；new 总是创建新IP
        wan_ip: any
        # 外网带宽
        wan_capacity: 10m
        # 作为ansible_host的地址类型：lan_ip私有IP（默认）, wan_ip公网IP
        ssh_host_by: wan_ip
        # ansible主机分组
        groups:
          - jump
      # 同时定义两台云主机 debian-test-a 和 debian-test-b
      - name: 'debian-test-w-{a..b}'
        present: true
        # 挂载云硬盘，其中hd-test-a挂载到debian-test-a， hd-test-b挂载到 debian-test-b
        volumes:
          - '*:hd-test-{a..b}'
        # 使用 debian-test-gw 作为 ssh 跳板机
        ssh_jump_host: debian-test-gw
        # ansible主机分组
        groups:
          - worker
        # ansible主机变量
        vars:
          host_var1: value
  roles: 
    - xiaopal.npc_setup
  tasks:
    - debug: msg={{groups["all"]}}
    # 等待跳板机ssh服务就绪
    - wait_for: port=22 host="{{npc.instances['debian-test-gw'].wan_ip}}" search_regex=OpenSSH delay=5

# 初始化云硬盘
- hosts: jump:worker
  tags: setup
  tasks:
    - with_items: '{{(npc_instance.volumes|default({})).values()}}'
      filesystem:
      # dev: /dev/vdc
        dev: '{{item.device}}'
        fstype: '{{item.fstype|default("ext4",true)}}'
        resizefs: true
    - with_items: '{{(npc_instance.volumes|default({})).values()}}'
      mount: 
        path: '{{item.path|default("/volumes/"~item.name, true)}}'
        src: '{{item.device}}'
        fstype: '{{item.fstype|default("ext4",true)}}'
        state: mounted

# 操作worker节点
- hosts: worker
  tags: setup
  tasks:
    - ping:
    - setup:
    - copy: 
        dest: /volumes/hd1/npc_instance.json
        content: "{{ npc_instance | to_json }}"

# 修改跳板机hosts
- hosts: jump
  tags: setup
  tasks:
    - blockinfile:
        path: /etc/hosts
        block: |
          {% for host in groups["worker"] %}{{ hostvars[host].npc_instance.lan_ip }} {{ host }}
          {% endfor %}

# 清理：删除所有主机和云硬盘
- hosts: localhost
  gather_facts: no
  tags: cleanup
  vars:
    npc_volumes:
      - name: hd-test-{gw,{a..b}}
        present: false
    npc_instances: 
      - name: 'debian-test-gw'
        present: false
      - name: 'debian-test-w-{a..b}'
        present: false
    npc_setup:
      add_hosts: false
  roles: 
    - xiaopal.npc_setup
EOF

```


## npc setup
```
# npc playbook --setup <<EOF
---
npc_volumes:
  - name: test-hd-{1,2}
    capacity: 10G
npc_instances:
  - name: test-vm
    instance_type: {cpu: 2, memory: 4G}
    instance_image: Debian 8.6
    ssh_keys:
      - Xiaohui-GRAYPC 
    volumes:
      - test-hd-1
      - test-hd-2
EOF

# npc playbook --setup <<EOF
---
npc_volumes:
  - name: test-hd-{1,2}
    present: false
npc_instances:
  - name: test-vm
    present: false
EOF

```

## 支持VPC 
```
# npc playbook -<<EOF
---
- hosts: localhost
  gather_facts: no
  roles:
    - role: xiaopal.npc_setup
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
          ssh_keys:
            - Xiaohui-GRAYPC
          volumes:
            - name: test-hd-1
            - test-hd-2
          present: yes
  tasks:
    - debug: msg={{npc}}
EOF




# npc playbook --setup <<EOF
---
npc_ssh_key: { name: test-ssh-key }

npc_instances:
  - name: vpc-instance-01
    zone: cn-east-1b
    instance_type: {series: 2, type: 2, cpu: 4, memory: 8G}
    instance_image: Debian 8.6
    vpc: test-vpc
    vpc_subnet: default
    vpc_security_group: test_group
    vpc_inet: yes
    vpc_inet_capacity: 10m
    present: yes

npc_vpc_networks:
  - name: test-vpc
    present: yes
    cidr: 10.177.0.0/16
    subnets:
      - subnet: default/10.177.231.0/24
        zone: cn-east-1b
      - subnet: 10.177.232.0/24
        zone: cn-east-1b
    security_groups:
      - security_group: test_group
        rules:
          - rule: ingress, 0.0.0.0/0, icmp
          - rule: ingress, default, all
          - rule: ingress, 10.0.0.0/8, {icmp,tcp/22,tcp/80,tcp/443,tcp/8000-9000}
          - rule: egress, 10.0.0.1, tcp/80-90
            present: no
      - security_group: unuse_group
        present: no
    route_tables:
      - route_table: '{main_route_table,test_table}'
        routes:
          - route: 192.168.99.0/24
            via_instance: vpc-instance-01

EOF

```


## 支持新版OpenAPI虚拟机规格及DNS托管域（NEW）
```
# npc playbook -<<EOF
---
- hosts: localhost
  gather_facts: no
  roles:
    - role: xiaopal.npc_setup
      npc_dns_zones:
        - name: in-addr.arpa
          fallthrough: yes
          vpc: defaultVPCNetwork
        - name: example.com
          vpc: defaultVPCNetwork
      npc_instances:
        - name: test-vm-1
          zone: cn-east-1b
          instance_type: {spec: "nvm.e2.large8"}
          instance_image: Debian 8.6
          vpc: defaultVPCNetwork
          vpc_subnet: default
          vpc_security_group: default
          vpc_inet: yes
          vpc_inet_capacity: 10m
          ssh_keys:
            - Xiaohui-GRAYPC
          present: yes
        - name: test-vm-2
          zone: cn-east-1b
          instance_type: {"cpu":4,"memory":"8G","series":2,"type":2}
          instance_image: Debian 8.6
          vpc: defaultVPCNetwork
          vpc_subnet: default
          vpc_security_group: default
          vpc_inet: yes
          vpc_inet_capacity: 10m
          ssh_keys:
            - Xiaohui-GRAYPC
          present: yes
  tasks:
    - debug: msg={{npc}}
EOF

```


## 支持新版OpenAPI DNS资源记录集创建（NEW）
```
# npc playbook -<<EOF
---
- hosts: localhost
  gather_facts: no
  roles:
    - role: xiaopal.npc_setup
      npc_dns_record_sets:
        - record_set: A, test{1..100}.example.com @example.com
          ttl: 3600
          records: 
            - '*:1.1.1.{1..100}'
        - record_set: A, test.example.com @example.com
          absent_records: 
            - 1.1.1.1
          present_records: 
            - 2.2.2.2
        - record_set: CNAME, t{1..100}.example.com, 3600 @example.com
          present_records: 
            - test.example.com
        - record_set: SRV, _t{1..100}._tcp.example.com, 3600 @example.com
          records: 
            - '@:1 0 8888 test{1..100}.example.com'
  tasks:
    - debug: msg={{npc}}
EOF

# npc playbook -<<EOF
---
- hosts: localhost
  gather_facts: no
  roles:
    - role: xiaopal.npc_setup
      npc_dns_zones:
        - name: example.com
          vpc: defaultVPCNetwork
          record_sets:
            - record_set: A, test{1..100}.example.com
              records: 
                - '*:1.1.1.{1..100}'
            - record_set: A, test.example.com
              absent_records: 
                - 1.1.1.1
              present_records: 
                - 2.2.2.2
            - record_set: CNAME, t{1..100}.example.com
              present_records: 
                - test.example.com
            - record_set: SRV, _t{1..100}._tcp.example.com, 60
              records: 
                - '@:1 0 8888 test{1..100}.example.com'
          
  tasks:
    - debug: msg={{npc}}
EOF

```

# 云主机负载均衡（NEW）
```
# npc playbook --setup <<EOF
---
npc_load_balancings:
  - name: lb-test
    vpc: defaultVPCNetwork
    vpc_subnet: default
    vpc_security_group: default
    capacity: 10m
    present: yes
EOF

# npc playbook --setup <<EOF
---
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
    ssh_keys:
      - Xiaohui-GRAYPC
    present: yes
npc_load_balancings:
  - name: lb-test
    vpc: defaultVPCNetwork
    vpc_subnet: default
    vpc_security_group: default
    capacity: 10m
    present: yes
    target_groups:
      - target_group: test-target-1
        targets:
          - test-vm/8888
      - target_group: test-target-{2,3}
        absent_targets:
          - test-vm/4444
        present_targets:
          - test-vm/8888
    listeners:
      - listener: test-http/80/http
        rules:
          - path: /
            target_group: test-target-1
      - listener: test-https/443/https
        present_rules:
          - host: www.example.com
            path: /new
            cert: www-example-com
            target_group: test-target-2
        absent_rules:
          - host: www.example.com
            path: /old
            cert: www-example-com
            target_group: test-target-3

EOF

```