#!/bin/bash
apt-get update && apt-get install -y socat
socat TCP-LISTEN:${var.sql_proxy_port},fork,reuseaddr TCP:${module.mysql.db_ip_address}:${var.sql_proxy_port} &