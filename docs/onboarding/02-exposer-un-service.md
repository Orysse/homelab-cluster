# Exposer un service sur abe.lc

Le chemin d'une requête :

```
Internet → https://blog.abe.lc → box → Traefik (HTTPS, certificat *.abe.lc déjà fait)
         → ton HTTPRoute → ton Service → tes pods
```

Tu écris un **Namespace** (avec le bon label), un **Deployment** (tes conteneurs), un
**Service** (une adresse stable devant eux) et un **HTTPRoute** (quelle adresse publique mène
à quel Service). Le DNS (`*.abe.lc` pointe déjà sur la maison), le HTTPS, la redirection
HTTP → HTTPS et les en-têtes de sécurité sont automatiques.

## 1. Exemple complet

`blog.yaml` :

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: blog
  labels:
    gateway-access: public                          # autorise ses routes sur la Gateway publique
    pod-security.kubernetes.io/enforce: restricted  # pas de conteneur root (voir § 4)
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: blog
  namespace: blog
spec:
  replicas: 1
  selector:
    matchLabels: { app: blog }
  template:
    metadata:
      labels: { app: blog }
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: web
          image: nginxinc/nginx-unprivileged:1.31.6-alpine   # toujours une version précise
          ports:
            - containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { memory: 128Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: blog
  namespace: blog
spec:
  selector: { app: blog }
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: blog
  namespace: blog
spec:
  parentRefs:
    - name: public
      namespace: kube-system
      sectionName: https
  hostnames:
    - blog.abe.lc
  rules:
    - backendRefs:
        - name: blog                    # ton Service
          port: 80
```

## 2. Le déployer

**Pour essayer** : `kubectl apply -f blog.yaml`, puis
`kubectl -n blog rollout status deploy/blog` et `curl -I https://blog.abe.lc`.
Tu peux aussi coller le YAML dans Headlamp (https://k8s.abe.lc, bouton *Create*).

**Pour que ça dure** : une pull request sur
[homelab-cluster](https://github.com/Orysse/homelab-cluster), comme toutes les apps du
homelab (section *Adding an app* du README) :

1. `apps/blog/blog.yaml` avec le contenu ci-dessus, en écrivant `blog.${DOMAIN}` au lieu de
   `blog.abe.lc` (Flux remplace la variable).
2. `apps/blog/kustomization.yaml` (copie celui de `apps/vitrine/`, qui ajoute aussi la version
   de l'image en label).
3. Une ligne `- blog` dans `apps/kustomization.yaml`.
4. Merge, puis `flux reconcile kustomization apps --with-source` pour ne pas attendre.

Ce qui est dans git est versionné, relu, et revient tout seul si le cluster est reconstruit.
Ce qui n'est créé qu'à la main disparaît dans ce cas.

Pour suivre un déploiement : `flux get kustomizations`, puis
`kubectl -n blog get pods`. `flux events --for Kustomization/apps` dit pourquoi ça bloque.

## 3. Choisir l'adresse

- **Public** : `<nom>.abe.lc`, Gateway `public`, label de namespace `gateway-access: public`.
  Un seul niveau sous `abe.lc` (`blog.abe.lc` oui, `a.blog.abe.lc` non : le certificat
  `*.abe.lc` ne le couvre pas).
- **Interne** (LAN et VPN seulement, pour tout ce qui a une interface d'admin) :
  `<nom>.int.abe.lc`, Gateway `internal`, label `gateway-access: internal`.

**Vérifie que l'adresse est libre** (`kubectl get httproute -A`) : deux routes sur le même
nom entrent en conflit (la plus ancienne gagne), et tu casserais le site de quelqu'un
d'autre.

Plusieurs services sur une même adresse, par chemin :

```yaml
  rules:
    - matches: [{ path: { type: PathPrefix, value: /api } }]
      backendRefs: [{ name: api, port: 80 }]
    - backendRefs: [{ name: front, port: 80 }]
```

Uniquement du HTTP(S). Pas de Service `LoadBalancer` ou `NodePort` pour publier : tout passe
par Traefik.

## 4. Images : pas de root

Avec le label `pod-security.kubernetes.io/enforce: restricted`, un conteneur qui tourne en
root, ou sans le `securityContext` de l'exemple, est refusé. L'erreur apparaît dans
`kubectl -n blog get events` avec le message `violates PodSecurity "restricted"`. Garde ce
label : une appli compromise reste alors enfermée dans son conteneur.

- Prends une image prévue pour ça (`nginx-unprivileged`, les images `distroless`
  `:nonroot`, la plupart des images d'applis récentes).
- Sinon, impose un utilisateur : `runAsUser: 1000` dans le `securityContext` du pod. L'appli
  ne peut alors pas écouter sous le port 1024 : utilise 8080, et laisse le Service traduire
  en 80.
- Si l'image écrit dans son système de fichiers et plante, monte un `emptyDir` sur le
  dossier concerné (`/tmp`, `/var/cache/…`).

Image privée (GitHub, par exemple) :

```bash
kubectl -n blog create secret docker-registry ghcr --docker-server=ghcr.io \
  --docker-username=<toi> --docker-password=<token avec read:packages>
```

puis `imagePullSecrets: [{ name: ghcr }]` dans le `spec` du pod.

## 5. Secrets, stockage, base de données

- **Secrets** (clés d'API, mots de passe) : dans OpenBao (https://bao.int.abe.lc), sous
  `kv/apps/<namespace>/<nom>`. L'app les lit avec un `ExternalSecret` : exemple dans le
  README, section *Application secrets*. Un namespace ne lit que ses propres secrets. Pour un
  essai rapide, un `kubectl create secret generic` suffit, mais jamais de secret en clair
  dans git : le repo est public.
- **Données persistantes** : un PersistentVolumeClaim. Le stockage est sur le serveur du
  homelab (NFS, classe `nfs` par défaut), avec des snapshots toutes les heures, mais **pas
  encore de sauvegarde hors site**.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: blog-data, namespace: blog }
spec:
  accessModes: [ReadWriteMany]
  resources: { requests: { storage: 1Gi } }
```

- **Base de données** : pas de SQLite ni de PostgreSQL sur un volume NFS (le NFS gère mal
  les verrous de fichiers, risque de corruption). Il y a un PostgreSQL sur le serveur, avec
  une base par namespace dont OpenBao gère le mot de passe : demande à Abel d'en ajouter une
  (c'est dans `homelab-nix`). L'app lit ensuite ses identifiants comme Grafana ou Pocket-ID
  (`infrastructure/configs/monitoring/grafana-secrets.yaml`).

## 6. Être prévenu si ça tombe

Ajoute ton adresse à la page de statut : une entrée dans `apps/gatus/config.yaml`
(https://status.abe.lc). Si elle échoue, une alerte part par mail.

## 7. Quand ça ne marche pas

| Symptôme | Où regarder |
|---|---|
| Le pod ne démarre pas | `kubectl -n blog describe pod <pod>`, `kubectl -n blog get events --sort-by=.lastTimestamp` |
| Le pod redémarre en boucle | `kubectl -n blog logs <pod> --previous` |
| `404` sur l'adresse | `kubectl -n blog describe httproute blog` : il faut `Accepted: True` et `ResolvedRefs: True`. `NotAllowedByListeners` = il manque le label `gateway-access` sur le namespace |
| `503` | le Service ne trouve pas de pod prêt : les `labels` du pod et le `selector` du Service doivent correspondre, et le `targetPort` doit être le port du conteneur |
| Rien ne se déploie après un merge | `flux get kustomizations`, `flux events --for Kustomization/apps` |

Les logs de tous les pods sont aussi dans Grafana (https://grafana.int.abe.lc, *Explore* →
VictoriaLogs).

Tester sans passer par Internet : `kubectl -n blog port-forward svc/blog 8080:80`, puis
http://localhost:8080.
