#cloud-config
coreos:
  etcd2:
    discovery: ${discovery_url}

    advertise-client-urls: "http://$private_ipv4:2379,http://$private_ipv4:4001"

    initial-advertise-peer-urls: "http://$private_ipv4:2380"

    listen-client-urls: "http://0.0.0.0:2379,http://0.0.0.0:4001"
    listen-peer-urls: "http://$private_ipv4:2380,http://$private_ipv4:7001"

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
