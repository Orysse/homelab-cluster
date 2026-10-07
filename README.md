# homelab-cluster

Ce qui tourne **dans** le cluster k3s du homelab, appliqué par [Flux](https://fluxcd.io)
(GitOps) : on pousse sur `main`, le cluster converge. Aucun `kubectl apply` à la main.

Les machines (NUC, microVMs, k3s, installation de Flux) sont dans le repo du socle,
`homelab-nix`, en Nix.

## Arborescence = ordre d'application

```
clusters/homelab/          point d'entrée de Flux (le socle pointe ici)
├─ infrastructure.yaml     infra-controllers -> infra-configs
└─ apps.yaml               apps (après infra-configs)

infrastructure/
├─ controllers/            ce qui installe des CRD : MetalLB, cert-manager, Datadog Operator
└─ configs/                ce qui les utilise : pool d'IP MetalLB, config de Traefik,
                           [émetteurs Let's Encrypt, agent Datadog : en attente de leurs secrets]

apps/                      une app = un dossier, listé dans apps/kustomization.yaml
└─ site/                   page publique en texte brut (index.txt) à la racine du domaine
```

Chaque niveau attend que le précédent soit prêt (`dependsOn`).

## Variables venues du socle

Le réseau est défini **une seule fois**, dans la topologie Nix du socle, qui publie la
ConfigMap `flux-system/cluster-vars`. Flux substitue ces variables dans `infrastructure/configs`
et `apps` :

| Variable | Exemple | Usage |
|---|---|---|
| `${DOMAIN}` | `192-168-1-240.sslip.io` (puis `abelc.eu`) | hosts des Ingress |
| `${INGRESS_ADDRESS}` | `192.168.1.240` | IP du LoadBalancer de Traefik |
| `${INGRESS_POOL}` | `192.168.1.240-192.168.1.254` | IP que MetalLB peut attribuer |

Seule la forme `${VAR}` est substituée (`$hostname` dans nginx.conf ne l'est pas). Pour
exclure un objet : annotation `kustomize.toolkit.fluxcd.io/substitute: disabled`.

## Ajouter une app

1. `apps/<app>/<app>.yaml` : Namespace, Deployment, Service, Ingress (partir de `site/`).
   Image avec tag figé, `resources` toujours renseignées, host `<sous-domaine>.${DOMAIN}`.
2. `apps/<app>/kustomization.yaml` qui liste ce fichier.
3. Une ligne dans `apps/kustomization.yaml`.
4. `git push`.

## Règles

- Images et charts **figés** (tag / version). Jamais `:latest`.
- **Aucun secret en clair** : le repo est public. Les secrets sont des fichiers
  `*.sops.yaml`, chiffrés avec sops (voir ci-dessous).
- Fichiers de config montés depuis une ConfigMap : passer par `configMapGenerator`
  (nom suffixé d'un hash => les pods redémarrent quand le contenu change).

## Secrets (sops + age)

Un Secret s'écrit en clair dans `<chemin>/<nom>.sops.yaml`, puis se chiffre sur place :

```bash
sops --encrypt --in-place apps/<app>/<nom>.sops.yaml   # chiffre data/stringData seulement
sops apps/<app>/<nom>.sops.yaml                        # éditer (déchiffre/rechiffre)
```

Destinataires (`.sops.yaml`) : la clé perso de l'admin (`~/.config/sops/age/keys.txt`,
sauvegardée dans Bitwarden) et `kube-1`, dont la clé SSH d'hôte convertie en age est posée
par le socle dans `flux-system/sops-age`. Flux déchiffre `infra-configs` et `apps`.
Si kube-1 change d'identité : mettre à jour sa clé dans `.sops.yaml`, puis
`sops updatekeys <fichier>` sur chaque secret.

## Vérifier en local

```bash
nix run nixpkgs#kustomize -- build apps
nix run nixpkgs#flux -- get kustomizations -A        # avec le kubeconfig du cluster
```
