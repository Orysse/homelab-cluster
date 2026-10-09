# Exposer un service sur lenny.abe.lc

Le chemin d'une requête :

```
Internet → https://blog.lenny.abe.lc → Traefik (HTTPS, certificat déjà fait)
         → ton HTTPRoute → ton Service → tes pods (namespace lenny)
```

Tu écris trois objets : un **Deployment** (tes conteneurs), un **Service** (une adresse
stable devant eux) et un **HTTPRoute** (quelle adresse publique mène à quel Service).
Le HTTPS, le certificat, la redirection HTTP → HTTPS et les en-têtes de sécurité sont
automatiques.

## 1. Exemple complet

`blog.yaml` :

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: blog
  namespace: lenny
spec:
  replicas: 1
  selector:
    matchLabels: { app: blog }
  template:
    metadata:
      labels: { app: blog }
    spec:
      securityContext:                  # obligatoire ici : pas de root (voir § 3)
        runAsNonRoot: true
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: web
          image: nginxinc/nginx-unprivileged:1.31.6-alpine  # toujours une version précise
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
  namespace: lenny
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
  namespace: lenny
spec:
  parentRefs:
    - name: public
      namespace: kube-system
      sectionName: lenny-subdomains     # pour *.lenny.abe.lc ; "lenny" pour lenny.abe.lc
  hostnames:
    - blog.lenny.abe.lc
  rules:
    - backendRefs:
        - name: blog                    # ton Service
          port: 80
```

```bash
kubectl apply -f blog.yaml
kubectl rollout status deploy/blog
curl -I https://blog.lenny.abe.lc
```

Tu peux aussi coller ce YAML dans Headlamp (https://k8s.abe.lc, bouton *Create*).

## 2. Choisir l'adresse

| Adresse | `sectionName` |
|---|---|
| `lenny.abe.lc` | `lenny` |
| `n'importe-quoi.lenny.abe.lc` | `lenny-subdomains` |

Pour servir les deux dans un même HTTPRoute, mets deux `parentRefs` (un par `sectionName`)
et les deux noms dans `hostnames`. Un seul niveau sous `lenny.abe.lc` : `a.lenny.abe.lc` oui,
`a.b.lenny.abe.lc` non (le certificat ne le couvre pas).

Une autre adresse (`vitrine.abe.lc`, ton propre domaine…) est refusée : la route reste
`Accepted: False`. Pour un domaine à toi, demande à Abel.

Plusieurs services sur une même adresse, par chemin :

```yaml
  rules:
    - matches: [{ path: { type: PathPrefix, value: /api } }]
      backendRefs: [{ name: api, port: 80 }]
    - backendRefs: [{ name: front, port: 80 }]
```

## 3. Images : pas de root

Le namespace applique la politique Kubernetes **`restricted`** : un conteneur qui tourne en
root, ou sans le `securityContext` de l'exemple, est refusé à la création du pod. L'erreur
apparaît dans `kubectl get events` ou `kubectl describe rs`, avec le message
`violates PodSecurity "restricted"`.

- Prends une image prévue pour ça (`nginx-unprivileged`, les images `distroless`
  `:nonroot`, la plupart des images d'applis récentes).
- Sinon, impose un utilisateur : `runAsUser: 1000` dans le `securityContext` du pod. L'appli
  ne peut alors pas écouter sous le port 1024 : utilise 8080, et laisse le Service traduire
  en 80.
- Si l'image écrit dans son système de fichiers et plante, monte un `emptyDir` sur le
  dossier concerné (`/tmp`, `/var/cache/…`).

Image privée (GitHub, par exemple) :

```bash
kubectl create secret docker-registry ghcr --docker-server=ghcr.io \
  --docker-username=<toi> --docker-password=<token avec read:packages>
```

puis `imagePullSecrets: [{ name: ghcr }]` dans le `spec` du pod.

## 4. Secrets, configuration, stockage

- **Secrets** (clés d'API, mots de passe) : `kubectl create secret generic blog-env
  --from-literal=API_KEY=...`, puis `envFrom: [{ secretRef: { name: blog-env } }]` dans le
  conteneur. Ne les mets jamais en clair dans un repo git public.
- **Configuration** : un ConfigMap, monté en fichier ou en variables d'environnement.
- **Données persistantes** : un PersistentVolumeClaim. Le stockage est sur le serveur du
  homelab (NFS), avec des snapshots toutes les heures, mais **pas encore de sauvegarde hors
  site** : garde une copie de ce qui compte.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: blog-data, namespace: lenny }
spec:
  accessModes: [ReadWriteMany]
  resources: { requests: { storage: 1Gi } }
```

Monté dans le pod avec `volumes` + `volumeMounts`. Le volume survit aux redémarrages et à la
suppression des pods.

- **Base de données** : pas de SQLite ni de PostgreSQL sur ce volume (le NFS gère mal les
  verrous de fichiers, risque de corruption). Demande à Abel une base PostgreSQL : il en
  crée une sur le serveur, et tu en reçois les identifiants dans ton namespace.

## 5. Déployer depuis git (optionnel)

Plutôt que `kubectl apply` à la main, le cluster peut suivre ton repo (Flux, GitOps) : tu
pousses, ça se déploie.

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata: { name: mon-repo, namespace: lenny }
spec:
  url: https://github.com/<toi>/<repo>
  ref: { branch: main }
  interval: 5m
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: { name: mon-repo, namespace: lenny }
spec:
  serviceAccountName: flux        # obligatoire ici : Flux agit avec tes droits, pas plus
  sourceRef: { kind: GitRepository, name: mon-repo }
  path: ./deploy                  # le dossier de ton repo qui contient tes YAML
  prune: true                     # ce que tu supprimes du repo est supprimé du cluster
  interval: 10m
```

Suivi : `flux get kustomizations -n lenny`, et `flux reconcile kustomization mon-repo -n
lenny --with-source` pour ne pas attendre. Repo privé : une deploy key, voir
`flux create secret git --help`.

## 6. Quand ça ne marche pas

| Symptôme | Où regarder |
|---|---|
| Le pod ne démarre pas | `kubectl get pods`, `kubectl describe pod <pod>`, `kubectl get events --sort-by=.lastTimestamp` |
| Le pod redémarre en boucle | `kubectl logs <pod> --previous` |
| `404` sur l'adresse | `kubectl describe httproute blog` : il faut `Accepted: True` et `ResolvedRefs: True` |
| `503` | le Service ne trouve pas de pod prêt : les `labels` du pod et le `selector` du Service doivent correspondre, et le `targetPort` doit être le port du conteneur |
| `exceeded quota` | tu as atteint les limites du namespace (CPU, mémoire, pods, disque) |

Tester sans passer par Internet : `kubectl port-forward svc/blog 8080:80`, puis
http://localhost:8080.

## Limites à connaître

- Uniquement du HTTP(S), via un HTTPRoute. Pas de `LoadBalancer`, pas de `NodePort`, pas de
  port TCP/UDP brut.
- Tes pods sortent vers Internet, mais ne voient ni le réseau de la maison ni les autres
  services du homelab.
- Le homelab tourne sur une seule machine : il peut y avoir des coupures (mises à jour,
  pannes). Abel est prévenu automatiquement, mais ne compte pas sur une disponibilité de
  production.
