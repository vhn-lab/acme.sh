# Recette DNS-01 manuelle pour IP Office

Cette recette valide l'émission ACME sans fournir de secret DNS à acme.sh et
sans déployer de certificat dans Avaya.

## Périmètre initial

- cible : `ipo` uniquement ;
- `ipos` reste désactivé ;
- autorité : environnement staging de Let's Encrypt ;
- challenge : DNS-01 manuel ;
- aucun appel à `gen_certs.sh` ;
- aucun redémarrage de service Avaya ;
- aucun certificat de staging installé dans Avaya.

## Précontrôles

Vérifier que l'installation utilise toujours le répertoire attendu :

```sh
/root/orange/script/acme.sh/acme.sh \
  --home /root/orange/script/acme.sh \
  --version
```

Vérifier également la résolution et l'accès à l'annuaire staging avant de
créer un ordre ACME.

## Création de l'ordre staging

```sh
/root/orange/script/acme.sh/acme.sh \
  --home /root/orange/script/acme.sh \
  --issue \
  --server letsencrypt_test \
  --dns \
  --yes-I-know-dns-manual-mode-enough-go-ahead-please \
  -d ipo.avaya-lab.vhn.ovh
```

La première exécution affiche un nom `_acme-challenge` et une valeur TXT
temporaires. Ne jamais enregistrer cette valeur dans Git ou dans les journaux
GitHub Actions.

Publier manuellement le TXT demandé, puis vérifier sa visibilité depuis un
résolveur public explicitement choisi :

```sh
dig +short @213.186.33.99 TXT \
  _acme-challenge.ipo.avaya-lab.vhn.ovh
```

## Finalisation manuelle

Après propagation du TXT, reprendre l'ordre sauvegardé :

```sh
/root/orange/script/acme.sh/acme.sh \
  --home /root/orange/script/acme.sh \
  --renew \
  --server letsencrypt_test \
  -d ipo.avaya-lab.vhn.ovh
```

Inspecter uniquement les métadonnées publiques du certificat obtenu : sujet,
SAN, émetteur, empreinte SHA-256 et dates de validité. Ne jamais afficher la clé
privée.

## Critères de réussite

- le challenge staging est validé ;
- le certificat couvre exactement `ipo.avaya-lab.vhn.ovh` ;
- les fichiers ACME restent sous `/root/orange/script/acme.sh` avec des droits
  privés ;
- aucun fichier sous `/opt/Avaya` ou dans les répertoires applicatifs ne change ;
- aucun service Avaya ne redémarre ;
- aucun secret ou TXT temporaire n'est ajouté au dépôt.

Le certificat staging doit rester isolé. Toute émission de production ou tout
déploiement Avaya nécessite une autorisation distincte.

Le mode DNS manuel ne permet pas le renouvellement automatique. Le cron ne doit
pas être considéré comme une solution de renouvellement tant qu'une intégration
DNS automatisée n'a pas été validée.
