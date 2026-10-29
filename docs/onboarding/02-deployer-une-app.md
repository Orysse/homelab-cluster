# Déployer une app

De ton image Docker à `https://monapp.abe.lc` en un dossier et une pull request. Le DNS, le
HTTPS, la redirection HTTP → HTTPS et les en-têtes de sécurité sont déjà gérés : tu n'as
rien à faire pour eux.

```
Internet → https://monapp.abe.lc → box → Gateway Cilium (HTTPS) → HTTPRoute → Service → tes pods
```

Prérequis : l'[accès admin](01-se-connecter.md) (Tailscale et `kubectl`), et git avec un
clone de [homelab-cluster](https://github.com/Orysse/homelab-cluster).

## 1. Une image qui tourne sans root

Le cluster refuse les conteneurs root. Ton image doit :

- **écouter sur un port au-dessus de 1024** (8080, 3000…), puisqu'un utilisateur normal ne
  peut pas ouvrir le port 80 ;
- **avoir une version précise** (`:1.4.2`, jamais `:latest`), pour que Renovate propose les
  mises à jour ;
- **être publique**, ou voir la section [Image privée](#image-privée).

Les images officielles récentes conviennent presque toutes. Pour une image construite par
la CI GitHub : *Packages* → ton image → *Package settings* → *Change visibility* → Public.

## 2. Copier le modèle

Choisis un nom, en minuscules avec des tirets si besoin. Il sert partout : namespace,
sous-domaine et noms des objets. Vérifie qu'il est libre avec `kubectl get httproute -A`,
car deux apps sur la même adresse se marchent dessus.

```bash
APP=blog                                   # le nom de ton app
cd homelab-cluster
git switch -c $APP
cp -r docs/onboarding/modele apps/$APP
sed -i "s/monapp/$APP/g" apps/$APP/*.yaml
echo "  - $APP" >> apps/kustomization.yaml
```

Dans la suite, `monapp` désigne ce nom.

Le dossier contient trois fichiers :

| Fichier | Rôle |
|---|---|
| `app.yaml` | le namespace, le Deployment (tes conteneurs), le Service, l'HTTPRoute (l'adresse) |
| `network-policy.yaml` | qui a le droit de parler à l'app, et à qui elle parle |
| `kustomization.yaml` | la liste des fichiers ; tu n'y touches pas |

## 3. Adapter

Dans `app.yaml`, les lignes marquées `À CHANGER` :

| Quoi | Où |
|---|---|
| L'image | `image:` |
| Le port de l'app | `containerPort:`, plus le même dans `network-policy.yaml` |
| Le chemin de santé | `readinessProbe` / `livenessProbe` : une URL qui répond 200 (`/`, `/health`…) |
| La mémoire | `resources` : environ ce que l'app consomme pour `requests`, le double pour `limits` |

**Publique ou interne ?** Tout ce qui a une interface d'admin reste interne.

| | Label du namespace | `parentRefs` | Adresse |
|---|---|---|---|
| Publique (Internet) | `gateway-access: public` | `public` | `monapp.${DOMAIN}` |
| Interne (LAN + VPN) | `gateway-access: internal` | `internal` | `monapp.int.${DOMAIN}` |

Écris bien `${DOMAIN}` et pas `abe.lc` : Flux remplace la variable. Il n'y a qu'un niveau
sous le domaine (`blog.abe.lc` marche, `a.blog.abe.lc` non : le certificat ne le couvre pas).

Variables d'environnement, dans le conteneur :

```yaml
          env:
            - { name: TZ, value: Europe/Paris }
```

## 4. Vérifier avant de pousser

```bash
kubectl kustomize apps/monapp > /dev/null && echo OK
```

Pour un essai réel sans passer par git, déploie le dossier à la main, regarde, puis
supprime :

```bash
kubectl kustomize apps/monapp | sed 's/${DOMAIN}/abe.lc/g' | kubectl apply -f -
kubectl -n monapp rollout status deploy/monapp
curl -I https://monapp.abe.lc
kubectl delete namespace monapp
```

## 5. Pousser

```bash
git add apps/monapp apps/kustomization.yaml
git commit -m "monapp: <ce qu'elle fait>"
git push -u origin monapp
```

Ouvre la pull request sur GitHub. Une fois mergée, Flux l'applique dans les minutes qui
suivent. Pour ne pas attendre :

```bash
flux reconcile kustomization apps --with-source
kubectl -n monapp get pods
curl -I https://monapp.abe.lc
```

Ce qui est dans git est versionné, relu, et revient tout seul si le cluster est reconstruit.
Un objet modifié à la main est remis comme dans git au passage suivant de Flux.

## 6. Être prévenu si elle tombe

Ajoute un check dans `apps/gatus/config.yaml` (copie une entrée existante). Il apparaît sur
https://status.abe.lc, et s'il échoue plus de 5 minutes, un mail d'alerte part.

Pour qu'il apparaisse aussi sur la page d'accueil (https://home.int.abe.lc), donne-lui l'un des
groupes `Plateforme`, `Observabilité` ou `Sites` : la page lit l'état dans Gatus, rien d'autre à
modifier.

## Aller plus loin

### Un secret (clé d'API, mot de passe)

Jamais dans git : le repo est public. Les secrets vont dans OpenBao, et un namespace ne lit
que les siens.

1. Dans https://bao.int.abe.lc (méthode *OIDC*, mount path `sso`) : moteur `kv`,
   chemin `apps/monapp/api`, une clé `token`.
2. Dans `apps/monapp/secrets.yaml` (et dans la liste de `kustomization.yaml`) :

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: { name: api, namespace: monapp }
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: openbao }
  target: { name: api }                                  # le Secret Kubernetes créé
  data:
    - secretKey: API_TOKEN
      remoteRef: { key: monapp/api, property: token }    # kv/apps/monapp/api
```

3. Dans le conteneur : `envFrom: [{ secretRef: { name: api } }]`.

Un secret généré automatiquement, que personne ne voit (clé de chiffrement, de session) :
un générateur crée la valeur une fois, OpenBao la garde, l'app la relit. Trois objets, à copier
depuis `apps/headscale/secrets.yaml` (la clé `noise`) en changeant les noms.

### Une base de données

Pas de SQLite ni de PostgreSQL sur un volume NFS : le NFS gère mal les verrous, et la base
finit corrompue. Il y a un PostgreSQL dans le cluster (CloudNativePG), avec une base par app :

1. Dans `infrastructure/configs/postgres/` : copie `databases/headscale.yaml` en
   `databases/monapp.yaml` (remplace `headscale` par le nom de ton namespace), ajoute-le à
   `kustomization.yaml`, et ajoute le rôle dans `cluster.yaml` (`managed.roles`), sur le
   modèle des autres. Ajoute aussi ton namespace à l'entrée de `network-policy.yaml`.
2. Le mot de passe est créé une fois et rangé dans OpenBao à `kv/apps/monapp/db`
   (`username`, `password`). Personne ne le connaît.
3. Dans ton app, un `ExternalSecret` le lit comme n'importe quel secret ; l'hôte est
   `main-rw.postgres.svc.cluster.local:5432`, la base porte le nom du namespace. Exemple
   avec l'URL de connexion : `apps/open-webui/secrets.yaml`.
4. Dans `network-policy.yaml`, décommente les blocs DNS et PostgreSQL.

Les sauvegardes sont automatiques : chaque nuit vers le serveur, gardées 30 jours.

### Des fichiers à garder

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: data, namespace: monapp }
spec:
  accessModes: [ReadWriteMany]
  resources: { requests: { storage: 1Gi } }
```

Puis un volume `persistentVolumeClaim: { claimName: data }` monté dans le conteneur. Le
stockage est sur le serveur (NFS), avec des snapshots toutes les heures, mais **sans
sauvegarde hors site pour l'instant**.

### Un fichier de configuration

```yaml
# dans kustomization.yaml
configMapGenerator:
  - name: config
    namespace: monapp
    files: [config.yaml]
```

Puis un volume `configMap: { name: config }`. Le nom reçoit un suffixe qui change avec le
contenu : les pods redémarrent tout seuls quand tu modifies le fichier.

### Image privée

```bash
kubectl -n monapp create secret docker-registry ghcr --docker-server=ghcr.io \
  --docker-username=<toi> --docker-password=<token GitHub avec read:packages>
```

puis `imagePullSecrets: [{ name: ghcr }]` dans le `spec` du pod. Ce secret-là est créé à la
main : à refaire si le cluster est reconstruit.

### Login Pocket-ID pour ton app

Si l'app sait faire de l'OIDC : déclare son client à côté d'elle, et l'opérateur Pocket-ID
le crée et écrit ses identifiants dans un Secret de ton namespace (`client_id`,
`client_secret`, `issuer_url`). Rien à copier à la main. Exemple :
`apps/open-webui/secrets.yaml` (le `PocketIDOIDCClient`) ; l'issuer est `https://auth.abe.lc`.

## Quand ça ne marche pas

| Symptôme | Cause probable, où regarder |
|---|---|
| Rien n'apparaît après le merge | `flux get kustomizations` ; il manque peut-être la ligne dans `apps/kustomization.yaml` |
| `violates PodSecurity "restricted"` | l'image tourne en root, ou il manque un bout du `securityContext` du modèle |
| Le pod redémarre en boucle | `kubectl -n monapp logs deploy/monapp --previous` |
| `Read-only file system` dans les logs | l'app écrit ailleurs que dans `/tmp` : monte un `emptyDir` sur ce dossier |
| `OOMKilled` | `limits.memory` trop bas |
| `404` sur l'adresse | `kubectl -n monapp describe httproute monapp` : `NotAllowedByListeners` = le label `gateway-access` ne correspond pas à la Gateway |
| `503` ou « no available server » | aucun pod prêt : la sonde échoue, ou le port est faux |
| L'app n'arrive pas à joindre une API ou sa base | `network-policy.yaml` : le flux n'est pas ouvert. Les paquets refusés sont visibles dans Hubble (https://hubble.int.abe.lc) |

Tous les logs sont dans Grafana (https://grafana.int.abe.lc, *Explore* → VictoriaLogs,
filtre `namespace="monapp"`). Pour tester sans passer par Internet :
`kubectl -n monapp port-forward svc/monapp 8080:80`, puis http://localhost:8080.

## Supprimer une app

Supprime `apps/monapp/` et sa ligne dans `apps/kustomization.yaml`, puis pousse : Flux
supprime tout ce qu'il avait créé. Un volume persistant est archivé sur le serveur, pas
effacé.
