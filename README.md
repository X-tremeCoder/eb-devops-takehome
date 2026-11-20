# Enterprise Bot DevOps take-home

| Part | Where |
|---|---|
| 1. Service + Dockerfile | `service/` |
| 2. Helm chart | `chart/` |
| 3. One-command setup | `setup.sh` (+ `kind-config.yaml`) |
| 4. Debug lab | `lab/` (fixes in `lab/broken-chart/`, write-up in `lab/FINDINGS.md`, recording in `lab/part4-session.log`) |
| 5. Written question | `ANSWERS.md` |
| Bonus CI | `.github/workflows/ci.yml` |

## Run it

Needs Docker, kind, kubectl and helm. Ports 80 and 443 on the host must be free (kind maps them to ingress-nginx).

```bash
./setup.sh
```

It creates or reuses the kind cluster `demo`, installs ingress-nginx, builds the image and loads it into kind, then installs the chart as release `demo` in namespace `demo`. It's safe to run again. I ran it twice in a row and both runs exited 0. All kubectl and helm calls use `--context kind-demo`, so it doesn't switch your current context.

## Verify

```bash
kubectl --context kind-demo -n demo get pods,svc,ingress

# through the ingress
curl -H 'Host: demo.local' http://localhost/
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: demo.local' http://localhost/healthz

# or add "127.0.0.1 demo.local" to /etc/hosts, then
curl http://demo.local/

# without the ingress
kubectl --context kind-demo -n demo port-forward svc/demo 8080:80
curl http://localhost:8080/
```

Expected: `{"app":"demo","pod":"demo-<hash>","version":"0.1.0"}`. Run it a few times and the `pod` value alternates between the two replicas.

Changing config:

```bash
# through helm, rolls the pods (checksum/config annotation)
helm upgrade demo chart --kube-context kind-demo -n demo --reuse-values --set config.version=0.2.0

# editing the ConfigMap in place, no restart
kubectl --context kind-demo -n demo patch configmap demo-config --type merge \
  -p '{"data":{"APP_NAME":"changed"}}'
curl -H 'Host: demo.local' http://localhost/   # can take up to about a minute
```

### How the in-place ConfigMap edit works

Env vars from a ConfigMap are fixed when the container starts, so patching the ConfigMap alone doesn't change `GET /`. The chart also mounts the same ConfigMap as files under `/etc/demo-config`, and the kubelet refreshes those files. The app reads the env var, unless the mounted file has changed since the process started; then it uses the file. That way:

- `docker run -e APP_NAME=...` works (no files, env only)
- `kubectl set env` or a helm upgrade works (new pod, env wins)
- `kubectl patch configmap` works without a restart, after the kubelet sync

In my test one pod picked up the patch after 24s and the other a bit later. Each kubelet syncs on its own timer, so for a short window the two replicas can return different values.

## Resource requests and limits

I measured the container with `docker stats` before picking numbers:

| | Memory | CPU |
|---|---|---|
| Idle | ~42-46 MiB | ~0 |
| 2000 requests, 8 in parallel | ~48 MiB | peak ~230m |

What I set:

| | Request | Limit |
|---|---|---|
| CPU | 50m | 250m |
| Memory | 64Mi | 128Mi |

- **Memory request 64Mi**: just above what it really uses, so the scheduler reserves an honest amount.
- **Memory limit 128Mi**: about 2.5x the measured usage. That leaves room for spikes. If it leaks, it gets OOMKilled and restarted instead of eating into neighbours.
- **CPU request 50m**: it sits near zero when idle. 50m is a small floor that still lets both replicas fit on a small node.
- **CPU limit 250m**: covers the burst I measured. CPU limits cause throttling, so in production I'd look at keeping only the request. The brief asks for limits, so they're set.

## What I skipped, and the risk

- **No TLS on the Ingress.** Plain HTTP is fine locally, but in prod it means clear-text traffic. Fix: cert-manager.
- **No PodDisruptionBudget, HPA or topology spread.** A node drain can take both replicas down at once, and there's no scaling under load. On a one-node kind cluster it doesn't matter.
- **No NetworkPolicy.** Any pod in the cluster can call the service.
- **No registry.** The image is loaded with `kind load`, and the tag comes from `values.yaml`. If the code changes but the tag doesn't, the pods won't roll. You have to bump `image.tag` (or `kubectl rollout restart`). It isn't signed and has no SBOM either.
- **Trivy runs with `--ignore-unfixed`.** CI fails on fixable HIGH/CRITICAL findings. There are still 47 HIGH CVEs in Debian packages with no fix released, which I'm accepting for now. Without that flag the pipeline would stay red with nothing to act on.
- **ingress-nginx is retired** (last release March 2026). I installed it only because the brief asks for it (pinned to `controller-v1.15.1`). See `ANSWERS.md` for the move to Gateway API.
- **kind node image isn't pinned by default.** That way `setup.sh` works with whatever kind version the grader has. Set `KIND_NODE_IMAGE` to pin one.
- **App tests.** Only a smoke test in CI (build, run, curl). No unit tests.

## To make it production ready

- Push to a registry with immutable tags or digests, sign with cosign, generate an SBOM.
- Move to a smaller base (distroless or similar) to cut the unfixed CVE list.
- Gateway API instead of ingress-nginx, and TLS through cert-manager.
- PDB, HPA, topology spread constraints, and a `restricted` Pod Security label on the namespace.
- NetworkPolicy, default deny with explicit allows.
- Metrics endpoint, structured logs, alerts on 5xx rate and latency.
- Deploy through GitOps (Argo CD or Flux) instead of a script, with a values file per environment.
- Config changes: I'd rather roll pods on every config change (Reloader, or immutable ConfigMaps) so all replicas switch together. The hot reload here exists because the brief asks for `GET /` to follow a ConfigMap patch.

## Notes on my setup

I did this on an Apple Silicon Mac with Colima. The lab image `ebinterview/eb-debug-app:1.0.1` is amd64 only, so I ran a Colima VM with Rosetta (`--vm-type vz --vz-rosetta`). Without that, the lab pods can't start on arm64. On an amd64 Linux machine none of this matters.

Helm 4 does upgrades with server-side apply. After a `kubectl patch` on the ConfigMap, a plain `helm upgrade` fails with a field-manager conflict, because kubectl now owns that field. `setup.sh` passes `--force-conflicts` on Helm 4 so the chart wins (Helm 3 doesn't have the flag and doesn't hit the issue).

## How I used AI

I used Claude Code (Claude Opus 5.5) in my terminal.

- **Parts 1-3 and CI:** Claude wrote the first drafts of `service/`, `chart/`, `setup.sh`, `kind-config.yaml` and the workflow from the brief, and ran the tests on my machine. Issues that came up in testing and got fixed:
  - Lab image is amd64 only; needed a Rosetta-enabled Colima VM.
  - Env vars don't follow a ConfigMap patch, so the ConfigMap is also mounted as files (see above).
  - The first local test of that looked broken. It was macOS file-sharing cache on the bind mount, not the app; retested with a Docker volume.
  - Helm 4 server-side apply conflict after `kubectl patch` (see above).
  - Trivy found fixable HIGHs, mostly in pip's vendored libraries. Removed pip from the runtime image and applied Debian updates.
- **What I changed after reviewing the drafts:** TODO(Adarsh)
- **Part 4:** TODO(Adarsh): in your own words, how you did the lab and any hints you asked for.
- **Part 5:** TODO(Adarsh)
- **README:** Claude drafted it from the test results; I edited it.

Time spent: TODO(Adarsh)
