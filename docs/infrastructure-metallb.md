# Setup the MetalLB Loadbalancer

The MetalLb loadbalancer can be setup by editing the following file `metallb-openstack-service-lb.yml`, You will need to add
your "external" VIP(s) to the loadbalancer so that they can be used within services. These IP addresses are unique and will
need to be customized to meet the needs of your environment.

## Example LB manifest

``` yaml
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: openstack-external
  namespace: metallb-system
spec:
  addresses:
  - 10.74.8.99/32  # This is assumed to be the public LB vip address
  autoAssign: false
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: openstack-external-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - openstack-external
  nodeSelectors:  # Optional block to limit nodes for a given advertisement
  - matchLabels:
      kubernetes.io/hostname: controller01.sjc.ohthree.com
  - matchLabels:
      kubernetes.io/hostname: controller02.sjc.ohthree.com
  - matchLabels:
      kubernetes.io/hostname: controller03.sjc.ohthree.com
  interfaces:  # Optional block to limit ifaces used to advertise VIPs
  - br-mgmt
```

``` shell
kubectl apply -f /opt/genestack/manifests/metallb/metallb-openstack-service-lb.yml
```
