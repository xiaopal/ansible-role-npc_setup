# ansible-role-npc_setup

## How to use



## npc setup
```
$ npc setup - --init-ssh-key <<EOF
{
  "npc_instance_image": "Debian 8.6",
  "npc_instance_type": {
    "cpu": 2,
    "memory": "4G"
  },
  "npc_ssh_key": {
    "name": "ansible"
  },
  "npc_instances": [
    {
      "name": "debian-{01,02}"
    },
    {
      "name": "ubuntu-{a..c}",
      "instance_image": "Ubuntu 16.04",
      "instance_type": {
        "cpu": 1,
        "memory": "2G"
      },
      "groups": [
        "ubuntu"
      ]
    }
  ]
}
EOF
```