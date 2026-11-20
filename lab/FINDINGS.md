# Findings: Part 4 debug lab

Recording: `lab/part4-session.log`. Fixes: one commit per defect in `lab/broken-chart/`.

Outputs below are copied from my recorded session unless marked otherwise. I used Claude for this part (details in the README): after the first defect it suggested most of the diagnostic commands, and it ran a few read-only checks on its own. Those outputs are marked "(Claude's check)".

The brief says six defects. I ended up making seven chart changes and found one more problem inside the image that the chart can't fix (last section). I've listed everything rather than try to match the count.

Final state: `./scenario.sh verify` shows 9/11. The two that fail are both the reporter image problem.

Environment note, not a chart defect: on the very first `./scenario.sh up`, `kubectl apply -f cluster-state/` ran `limits.yaml` before `namespace.yaml` (alphabetical order), so the LimitRange wasn't created:

```
namespace/debug-lab created
Error from server (NotFound): error when creating "cluster-state/limits.yaml": namespaces "debug-lab" not found
```

The second `up` created it (`limitrange/debug-lab-guardrails created`). This matters for defect 5 below.

---

## Defect 1: migrate Job has `restartPolicy: Always`

**Symptom**

```
Error: server-side apply failed for object debug-lab/migrate batch/v1, Kind=Job: Job.batch "migrate" is invalid: spec.template.spec.restartPolicy: Required value: valid values: "OnFailure", "Never"
```

**Cause:** a Job's pod must be allowed to finish. `Always` would restart it forever and the Job could never complete, so the API server rejects the object and the helm release fails.

**Fix:** `restartPolicy: Never` in `templates/migrate-job.yaml`. With `backoffLimit: 2`, each retry runs in a new pod and the failed pods stay around, so `kubectl logs` shows why each attempt failed. `OnFailure` would also be valid, but it restarts the container in the same pod and you only keep the last attempt's logs.

**How I found it:** the helm error from `./scenario.sh up` names the field and the allowed values. I checked `migrate-job.yaml` and it had `Always`.

---

## Defect 2: `runAsNonRoot` with a non-numeric image user

**Symptom:** every pod, including the Job, stuck in `CreateContainerConfigError`:

```
backend-7948fd6b4b-hxt7w    0/1     CreateContainerConfigError   0          4m55s
gateway-5cbdcd4bf8-rsvlk    0/1     CreateContainerConfigError   0          4m55s
metrics-547dccf75-hpb55     0/1     CreateContainerConfigError   0          4m55s
migrate-r8gxh               0/1     CreateContainerConfigError   0          15s
...
Warning  Failed  6s (x25 over 5m17s)  kubelet  spec.containers{backend}: Error: container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root
```

**Cause:** the image sets `USER nonroot`, a name, not a UID. With `runAsNonRoot: true` the kubelet has to prove the UID isn't 0, it can't do that from a username, so it refuses to start the container.

```
$ docker buildx imagetools inspect docker.io/ebinterview/eb-debug-app:1.0.1 --format '{{json .Image.Config.User}}'
"nonroot"
$ docker cp eb-inspect:/etc/passwd - | tar -xOf - | grep nonroot
nonroot:x:65532:65532:nonroot:/home/nonroot:/sbin/nologin
```

**Fix:** `runAsUser: 65532` and `runAsGroup: 65532` under every `runAsNonRoot: true` (6 templates). 65532 is the image's own `nonroot` user, so the app runs as its authors intended and the kubelet can verify it. I did not remove `runAsNonRoot` (that just turns the guard off), and rebuilding the image isn't allowed.

**How I found it:** all six workloads failing the same way pointed at something they share. `CreateContainerConfigError` means the container never started, so I looked at events instead of logs (`kubectl describe pod`, `kubectl get events`), then checked the image's user and found its UID in `/etc/passwd` with `docker create` + `docker cp`, since the image has no shell.

Side effect while applying this: helm then failed with `spec.template: Invalid value: ...: field is immutable`. A Job's pod template can't be changed after creation, and the old `migrate` Job from before the fix was still there. I deleted the stale Job (`kubectl -n debug-lab delete job migrate`) and helm recreated it from the fixed template. It then completed:

```
2026/11/20 11:43:52 eb-debug-app 2.0.0: migration starting (app=migrate, 2s of very important work)
2026/11/20 11:43:54 migration complete
```

In a real chart I'd make the migration a Helm hook with `helm.sh/hook-delete-policy: before-hook-creation`, so every upgrade replaces the Job.

---

## Defect 3: app listens on 8081, chart uses 8080

**Symptom:** backend, gateway and reporter `Running` but never Ready:

```
Warning  Unhealthy  4s (x19 over 94s)  kubelet  spec.containers{backend}: Readiness probe failed: Get "http://10.244.0.29:8080/healthz": dial tcp 10.244.0.29:8080: connect: connection refused

$ kubectl -n debug-lab logs backend-6865788b54-m6clb
eb-debug-app 2.0.0 starting: mode=api pod=backend-6865788b54-m6clb listening on :8081 (image default is 8081; set PORT to override)
```

**Cause:** `common.port: 8080` drives the containerPort, the probes and the Service targetPort, but nothing tells the app to listen there. It uses its default of 8081.

**Fix:** added `PORT` to the env of all five Deployments, set from `{{ .Values.common.port }}`. The chart stays the single source of truth for the port. Changing `common.port` to 8081 would also work, but it would quietly depend on an image default that could change in the next tag.

**How I found it:** the probe event said "connection refused" on 8080 (nothing listening, not a slow app), and the first log line said which port it was actually on.

---

## Defect 4: worker needs a writable `/var/cache/app`

**Symptom:**

```
worker-644f6d84cd-frzmh     0/1     CrashLoopBackOff             1 (8s ago)   11s

$ kubectl -n debug-lab logs worker-644f6d84cd-frzmh --previous
FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system — the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)

Last State:     Terminated
  Reason:       Error
  Exit Code:    1
```

**Cause:** `readOnlyRootFilesystem: true` (good) and the worker writes a cache under `/var/cache/app`.

**Fix:** an `emptyDir` volume mounted at `/var/cache/app` in `templates/worker.yaml`. The root filesystem stays read-only. Turning off `readOnlyRootFilesystem` would also stop the crash but drops the hardening. `CACHE_DIR=/tmp` wouldn't help because `/tmp` is read-only too.

**How I found it:** `--previous` logs, because the current container had already restarted, and `describe` for the exit code.

---

## Defect 5: metrics CPU above the namespace LimitRange

**Symptom:** after the other fixes, no new metrics pod appeared at all. The ReplicaSet couldn't create one:

```
Warning  FailedCreate  replicaset/metrics-749f5448c9  Error creating: pods "metrics-749f5448c9-z76tv" is forbidden: maximum cpu usage per Container is 1, but limit is 4
```

**Cause:** `values.yaml` gave metrics `requests.cpu: "2"` and `limits.cpu: "4"`. The `debug-lab-guardrails` LimitRange caps a container at 1 CPU, so admission rejects the pod.

This one was masked. The original metrics pod was created during the first `up`, when `limits.yaml` had failed (see the environment note), so it was admitted and only showed the same `runAsNonRoot` error as everything else. Once the LimitRange existed, every new metrics pod was rejected.

**Fix:** `50m` request / `200m` limit, the same as the other services. I can't change the LimitRange, and nothing showed that metrics needs more CPU than its siblings. With real usage data I'd size it from that.

**How I found it:** `kubectl get events` with the Normal ones filtered out. It's the only defect that never produces a pod, so pod-level commands show nothing.

---

## Defect 6: gateway points at the backend in the wrong namespace

**Symptom:** gateway `Running` but not Ready, probe returning 503:

```
readiness failed: backend not reachable: GET http://backend.default.svc:8080/healthz: Get "http://backend.default.svc:8080/healthz": dial tcp: lookup backend.default.svc on 10.96.0.10:53: no such host
GET /healthz -> 503
```

**Cause:** `BACKEND_URL: "http://backend.default.svc:8080"`. The backend lives in `debug-lab`, not `default`. The gateway's health check depends on reaching the backend, so it never goes Ready.

**Fix:** `BACKEND_URL: "http://backend:8080"`. The short name resolves through the pod's DNS search path in whatever namespace the chart is installed into. `backend.debug-lab.svc` would also work but breaks if the chart is installed elsewhere.

**How I found it:** gateway logs. The DNS error names the exact host it was trying.

---

## Defect 7: RoleBinding grants the Role to the wrong ServiceAccount

**Symptom:**

```
FAIL  ServiceAccount debug-lab/reporter cannot list pods

$ kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:reporter
no
```

Reporter log (Claude's check):

```
pod list failed: kubernetes API returned HTTP 403: ... "pods is forbidden: User \"system:serviceaccount:debug-lab:reporter\" cannot list resource \"pods\" in API group \"\" in the namespace \"debug-lab\"" ...
```

**Cause:** the Role `reporter-read` is fine (get/list pods only), but the RoleBinding's subject is the `default` ServiceAccount. The reporter runs as `reporter`.

**Fix:** the subject's name now comes from `{{ .Values.reporter.serviceAccountName }}`, the same value the Deployment uses, so the two can't drift apart. Afterwards `can-i` returns `yes`. I kept the Role as narrow as it was. Granting something broader would also make the 403 go away, but that's the wrong fix.

**How I found it:** the verify line, `kubectl auth can-i` to confirm, then reading `rbac.yaml`.

---

## Not fixed: the reporter image can only read 1 KB of the pod list

After defect 7 the 403 was gone, but the reporter still never went Ready, and `verify` kept failing `deployment reporter: 0/1 ready` and `reporter /report does not return a pod count`.

**Symptom (Claude's check):**

```
pod list failed: parse pod list: unexpected end of JSON input
GET /healthz -> 503
```

The full pod list it fetches is about 50 KB:

```
$ kubectl get --raw '/api/v1/namespaces/debug-lab/pods?limit=100' | wc -c
   50843
```

**What Claude tested to narrow it down** (throwaway pods, namespaces and one extra cluster, all deleted afterwards):

- 1 CPU instead of 200m: same error.
- 512Mi memory instead of 128Mi: same error.
- Writable root filesystem, and a writable `/tmp`: same error.
- Kubernetes v1.35.8 instead of v1.37.0: same error.
- A fake API server (own CA, `hostAliases` for `kubernetes.default.svc`) returning a complete, valid 50 KB list with `Content-Length`: same error. Serving lists of growing size, 406 bytes parsed fine and 1,497 bytes and up all failed.
- Disassembling the binary: the reporter's `listPods` wraps the response in an `io.LimitedReader` with `N = 0x400` (1024 bytes) before `io.ReadAll` and `json.Unmarshal`. The only env var the reporter reads is `NAMESPACE`, so nothing in the chart can change the limit.

**Conclusion:** `eb-debug-app:1.0.1` in reporter mode can't parse any real pod list, because one pod alone is several KB. Within the rules (no image changes) the chart can't fix this. I deliberately did not point the reporter's readiness probe somewhere else to make it show Ready. That would hide the alert without fixing anything.

**What I'd do next:** report it to the image owners with the evidence above. The fix is in the app: remove the 1 KB cap or raise it a lot, or decode with a streaming `json.Decoder`, and paginate with `limit`/`continue` for big namespaces. I'd also ask whether the intended setup avoids this and I've missed something, since the check is meant to pass.
