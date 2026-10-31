#!/bin/bash
ANSIBLE_HOST_KEY_CHECKING=false ansible-playbook -i inventory.ini site.yml
