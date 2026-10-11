# Onboarding

| Tu es… | Lis |
|---|---|
| **Visiteur** : tu veux voir le homelab | [Visite guidée](03-visiteur.md) |
| **Admin** : tu as un compte `admins` | [Se connecter](01-se-connecter.md), puis [Déployer une app](02-deployer-une-app.md) |

Les fichiers à côté :

- [`modele/`](modele/) : une app prête à copier (namespace, Deployment, Service, adresse,
  network policy), utilisée par [Déployer une app](02-deployer-une-app.md).
- [`kubeconfig.yaml`](kubeconfig.yaml) : le kubeconfig Pocket-ID, sans secret.

Pour le fonctionnement interne (Flux, secrets, réseau, sécurité) : le
[README du repo](../../README.md), en anglais, et le [cheatsheet](../cheatsheet.md) des
commandes d'exploitation.
