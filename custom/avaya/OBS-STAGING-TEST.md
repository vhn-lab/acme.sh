# Recette de validation OBS DNS-01

## Statut

Cette recette doit être exécutée sur une zone DNS de test avant toute activation
du renouvellement automatique en production.

L'API OBS n'étant pas encore disponible dans l'environnement de validation, les
tests automatisés du dépôt simulent ses réponses. Ils ne prouvent pas la
compatibilité avec l'API réelle.

## Objectifs

La recette doit confirmer que :

- l'authentification OBS fonctionne sans exposer le jeton ;
- un enregistrement TXT peut être créé puis supprimé ;
- la valeur transmise par acme.sh est publiée sans altération ;
- le renouvellement du jeton OBS est enregistré de manière atomique ;
- aucune information sensible n'apparaît dans les journaux ;
- la propagation DNS est compatible avec une validation ACME DNS-01.

## Prérequis

- utiliser une zone et un nom non critiques autorisés par OBS ;
- exécuter les commandes avec un compte autorisé ;
- disposer de `openssl`, `curl` et d'un outil de résolution DNS tel que
  `dig` ;
- installer le code depuis la branche approuvée du fork ;
- ne jamais saisir le jeton dans l'historique du shell, la ligne de commande,
  un ticket ou une conversation.

Le fichier réel de credentials doit être placé hors du dépôt :

```text
/etc/acme-avaya/obs-credentials.csv
```

Il doit appartenir à `root:root` et avoir le mode `0600`. Son format est :

```text
hostName;zoneName;apiToken
_acme-challenge.acme-test.example.fr;example.fr;JETON_FICTIF
```

Remplacer tous les noms et la valeur fictive localement. Ne jamais committer le
fichier réel.

## Point à confirmer : représentation de la valeur TXT

La documentation Swagger représente une chaîne JSON ainsi :

```json
{
  "type": "TXT",
  "value": "a txt record"
}
```

Les guillemets ci-dessus délimitent la chaîne JSON. Ils ne démontrent pas que
des caractères guillemets doivent être inclus dans la donnée TXT. La première
recette doit donc envoyer la valeur ACME brute. Par exemple, la donnée
`test-acme-obs-2026` doit être encodée ainsi :

```json
{
  "value": "test-acme-obs-2026"
}
```

Si des guillemets devaient réellement faire partie de la donnée, le JSON serait
au contraire :

```json
{
  "value": "\"test-acme-obs-2026\""
}
```

Ne modifier le module pour utiliser cette seconde forme qu'après une preuve
obtenue avec l'API réelle.

## Étape 1 — Contrôles locaux

Vérifier les droits sans afficher le contenu du fichier :

```sh
stat -c '%U:%G %a %n' /etc/acme-avaya/obs-credentials.csv
```

Résultat attendu :

```text
root:root 600 /etc/acme-avaya/obs-credentials.csv
```

Vérifier que le nom de test ne contient pas déjà un TXT :

```sh
dig +short TXT _acme-challenge.acme-test.example.fr
```

Consigner uniquement le résultat DNS public, jamais le jeton.

## Étape 2 — Test d'ajout OBS

Exécuter le module OBS via acme.sh dans l'environnement de recette avec une
valeur temporaire non secrète. Ne pas activer le cron à ce stade.

Critères de réussite :

- l'API répond avec un code de succès documenté par OBS ;
- le module ne journalise ni le jeton ni le contenu du fichier de credentials ;
- le nouveau jeton éventuellement retourné remplace atomiquement l'ancien ;
- aucun fichier temporaire contenant un secret ne reste présent.

## Étape 3 — Vérification DNS

Interroger d'abord les serveurs faisant autorité, puis un résolveur public :

```sh
dig +short TXT _acme-challenge.acme-test.example.fr
```

Une sortie telle que celle-ci est normale :

```text
"test-acme-obs-2026"
```

Les guillemets affichés par `dig` ne suffisent pas à conclure qu'ils font
partie de la valeur envoyée à l'API.

Le test est réussi si la donnée TXT reconstituée correspond exactement à la
valeur fournie par acme.sh.

## Étape 4 — Test de suppression

Déclencher la suppression du même TXT avec le module OBS, puis vérifier :

```sh
dig +short TXT _acme-challenge.acme-test.example.fr
```

Le résultat doit être vide après propagation. Si un enregistrement existait
avant la recette, vérifier qu'il n'a pas été supprimé ou modifié.

## Étape 5 — Test ACME staging

Après validation des opérations unitaires, lancer une émission avec
l'environnement de staging de l'autorité ACME. Ne pas déployer le certificat
obtenu sur Avaya.

Critères de réussite :

- acme.sh crée le TXT attendu ;
- l'autorité ACME valide le challenge ;
- acme.sh supprime le TXT ;
- aucun certificat de staging n'est transmis à IP Office ou ASBCE ;
- aucun secret n'apparaît dans les journaux.

La commande exacte sera complétée avec le FQDN de recette et les options
retenues au moment où l'accès OBS sera disponible.

## Étape 6 — Autorisation de production

Le passage en production reste interdit tant que les preuves suivantes ne sont
pas consignées :

- date et opérateur de la recette ;
- zone et FQDN de test, sans credential ;
- création TXT réussie ;
- valeur DNS exacte confirmée ;
- suppression TXT réussie ;
- rotation du jeton confirmée si applicable ;
- test ACME staging réussi ;
- contrôle des journaux réussi.

Une validation manuelle est ensuite requise avant d'activer le cron et avant
tout déploiement Avaya.
