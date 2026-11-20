# Answers

## Q1. Moving ~40 Ingresses from ingress-nginx to Gateway API with no downtime

**Approach, in order**

1. **Inventory first.** Export all 40 Ingresses and group them by the annotations they use. Plain host/path routing maps almost 1:1 to HTTPRoute. The risky ones use `rewrite-target`, `configuration-snippet`, `auth-url`, rate limits, canary or sticky sessions.
2. **Run both side by side.** Pick an implementation (Envoy Gateway, NGINX Gateway Fabric, Cilium, etc.), install the Gateway API CRDs and controller next to ingress-nginx, and give the Gateway its own load balancer IP. ingress-nginx keeps serving everything.
3. **Convert.** Use `ingress2gateway` as a starting point, then fix by hand. Set up TLS on the Gateway through cert-manager, and add ReferenceGrants where routes or secrets cross namespaces.
4. **Test before touching DNS.** Hit each host on the new IP with `curl --resolve`, and compare status codes, headers, redirects and auth with the old path.
5. **Cut over gradually.** Lower DNS TTLs a day ahead. Move low-risk hosts first, ideally with weighted DNS, and watch 4xx/5xx and latency for each host.
6. **Rollback stays easy.** Point DNS back. Don't touch ingress-nginx until its access logs show no traffic for a while, then remove the Ingress objects and the controller.

**What I expect to break**

- Annotation features with no direct Gateway equivalent: snippets, external auth, rate limiting, custom error pages. These need implementation-specific policies or app changes.
- Regex paths and rewrite behaviour differ.
- Different defaults: timeouts, max body size, websockets, client IP / X-Forwarded-For handling.
- cert-manager HTTP-01 solvers and external-dns need reconfiguring for Gateway resources.
- Dashboards and alerts built on ingress-nginx metrics go quiet. Rebuild them before the cutover, not after.
