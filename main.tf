provider "digitalocean" {}

variable "POD_NETWORK"      { default = "10.2.0.0/16" }
variable "SERVICE_IP_RANGE" { default = "10.3.0.0/24" }
variable "K8S_SERVICE_IP"   { default = "10.3.0.1" }
variable "DNS_SERVICE_IP"   { default = "10.3.0.10" }

resource "template_file" "cloud-config" {
    template = "${file("./cloud-config.tpl")}"
    vars {
        discovery_url = "${var.discovery_url}"
        region = "${var.region}"
    }
}

resource "template_file" "cloud-config-follower" {
    template = "${file("./cloud-config-follower.tpl")}"
    vars {
        discovery_url = "${var.discovery_url}"
        region = "${var.region}"
    }
}

resource "digitalocean_droplet" "core_leader" {
    count = "${var.leader_count}"

    image              = "coreos-stable"
    name               = "leader${count.index}.core"
    region             = "${var.region}"
    size               = "${var.leader_size}"
    ssh_keys           = ["${split(",", var.ssh_keys)}"]
    user_data          = "${template_file.cloud-config.rendered}"
    private_networking = true

    connection { user = "core" }

    provisioner "remote-exec" {
        inline = <<EOF
wget -qO- https://github.com/aybabtme/untilitworks/releases/download/0.2/untilitworks_linux.tar.gz | tar xvz
./untilitworks -q -retry e -exp.factor 1.5 -max 60s etcdctl cluster-health
EOF
    }
}

resource "digitalocean_droplet" "k8s_leader" {
    depends_on = ["digitalocean_droplet.core_leader"]

    image              = "coreos-stable"
    name               = "leader.kube"
    region             = "${var.region}"
    size               = "${var.leader_size}"
    ssh_keys           = ["${split(",", var.ssh_keys)}"]
    user_data          = "${template_file.cloud-config-follower.rendered}"
    private_networking = true

    connection { user = "core" }

    # make sure the etcd cluster is healthy
    provisioner "remote-exec" {
        inline = <<EOF
wget -qO- https://github.com/aybabtme/untilitworks/releases/download/0.2/untilitworks_linux.tar.gz | tar xvz
./untilitworks -retry e -exp.factor 1.5 -max 60s etcdctl cluster-health
EOF
    }

    # generate certs for our IP
    provisioner "local-exec" {
        command = <<CMD
mkdir certs
pushd certs

set -e

# root cert authority
openssl genrsa -out ca-key.pem 2048
openssl req -x509 -new -nodes -key ca-key.pem -days 10000 -out ca.pem -subj "/CN=kube-ca"

cat > openssl.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = kubernetes
DNS.2 = kubernetes.default
IP.1 = ${var.K8S_SERVICE_IP}
IP.2 = ${self.ipv4_address_private}
EOF

# API server keypair
openssl genrsa -out apiserver-key.pem 2048
openssl req -new -key apiserver-key.pem -out apiserver.csr -subj "/CN=kube-apiserver" -config openssl.cnf
openssl x509 -req -in apiserver.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out apiserver.pem -days 365 -extensions v3_req -extfile openssl.cnf

mkdir -p             ../tmpl/kube-master/etc/kubernetes/ssl/
cp ca.pem            ../tmpl/kube-master/etc/kubernetes/ssl/
cp apiserver.pem     ../tmpl/kube-master/etc/kubernetes/ssl/
cp apiserver-key.pem ../tmpl/kube-master/etc/kubernetes/ssl/

# k8s worker keypair
openssl genrsa -out worker-key.pem 2048
openssl req -new -key worker-key.pem -out worker.csr -subj "/CN=kube-worker"
openssl x509 -req -in worker.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out worker.pem -days 365

# admin keypair
openssl genrsa -out admin-key.pem 2048
openssl req -new -key admin-key.pem -out admin.csr -subj "/CN=kube-admin"
openssl x509 -req -in admin.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out admin.pem -days 365
CMD
    }

    # send the template files
    provisioner "file" {
      source = "tmpl/kube-master/"
      destination = "/tmp/kube-master/"
    }
    # render them!
    provisioner "remote-exec" {
      inline = <<EOF
set -e

wget -qO- https://github.com/aybabtme/temple/releases/download/0.2.1/temple_linux.tar.gz | tar xvz

./untilitworks -retry e -exp.factor 1.5 -max 60s etcdctl cluster-health
sudo ./temple tree -dst / -src /tmp/kube-master \
              -var MASTER_HOST=${self.ipv4_address_private} \
              -var ETCD_ENDPOINTS="${join(":4001,", digitalocean_droplet.core_leader.*.ipv4_address_private)}" \
              -var ADVERTISE_IP=${self.ipv4_address_private} \
              -var POD_NETWORK=${var.POD_NETWORK} \
              -var SERVICE_IP_RANGE=${var.SERVICE_IP_RANGE} \
              -var K8S_SERVICE_IP=${var.K8S_SERVICE_IP} \
              -var DNS_SERVICE_IP=${var.DNS_SERVICE_IP} \

sudo chmod 600 /etc/kubernetes/ssl/*-key.pem
sudo chown root:root /etc/kubernetes/ssl/*-key.pem

sudo systemctl daemon-reload
sudo systemctl start kubelet
sudo systemctl enable kubelet

curl http://127.0.0.1:8080/version
curl -XPOST -d'{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"kube-system"}}' "http://127.0.0.1:8080/api/v1/namespaces"

docker ps
systemctl status kubelet.service
EOF
    }
}
