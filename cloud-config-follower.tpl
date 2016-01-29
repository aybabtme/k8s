#cloud-config
coreos:
  etcd2:
    discovery: ${discovery_url}
    proxy: on
    listen-client-urls: "http://0.0.0.0:2379,http://0.0.0.0:4001"
    
  fleet:
    public-ip: "$public_ipv4"
    metadata: "region=${region}"

  flannel:
    etcd_prefix: "/coreos.com/network2"

  units:
    - name: etcd2.service
      enable: true
      command: start
    - name: fleet.service
      enable: true
      command: start
