# scw-snapshot-archiver

Serverless Job Scaleway : snapshot d'un volume d'Instance (l_ssd ou b_ssd), export en QCOW2 vers un
bucket Object Storage, suppression du snapshot, puis rétention des N derniers exports.

Image : `ghcr.io/tarbib/scaleway-auto-snapshot:latest`

## Variables d'environnement

| Variable | Défaut | Description |
|---|---|---|
| `SCW_ACCESS_KEY` | — | clé d'API IAM |
| `SCW_SECRET_KEY` | — | clé secrète IAM |
| `SCW_DEFAULT_PROJECT_ID` | — | projet cible |
| `VOLUME_ID` | — | UUID du volume |
| `BUCKET` | — | bucket de destination, **même région que le volume** |
| `ZONE` | `fr-par-1` | zone du volume |
| `RETENTION` | `3` | nombre d'exports `.qcow2` conservés dans le bucket |
| `PREFIX` | `snapshots` | racine des clés : `<PREFIX>/<instance>/autosnap-<date>.qcow2` |
| `LABEL` | nom de l'instance | force le nom du dossier |
| `EXPORT_TIMEOUT` | `7200` | timeout de l'export, en secondes |

Le dossier porte le nom de l'instance à laquelle le volume est attaché ; si l'instance est
renommée, un nouveau dossier apparaît et la rétention repart de zéro dans celui-ci.

## Droits IAM du job

`InstancesFullAccess` + `ObjectStorageFullAccess`, sur le projet concerné.

## Créer le job

```sh
scw jobs definition create \
  name=snapshot-archiver \
  image-uri=ghcr.io/tarbib/scaleway-auto-snapshot:latest \
  cpu-limit=140 memory-limit=256 local-storage-capacity=1000 job-timeout=3h \
  cron-schedule.schedule="0 2 * * *" cron-schedule.timezone="Europe/Paris" \
  environment-variables.VOLUME_ID=<uuid> \
  environment-variables.BUCKET=<bucket> \
  environment-variables.ZONE=fr-par-2 \
  environment-variables.RETENTION=3 \
  region=fr-par
```

Les clés d'API se passent via Secret Manager plutôt qu'en variables d'environnement en clair.

## Restaurer

Depuis la console : Object Storage > le bucket > menu de l'objet > **Import as snapshot**,
en choisissant le type Local Storage ou Block SSD. Puis créer une Instance à partir de ce snapshot.

En CLI :

```sh
scw instance snapshot create name=restore volume-type=l_ssd \
  bucket=<bucket> key=snapshots/<instance>/autosnap-20260821-020000.qcow2 zone=fr-par-2
```

## Notes

- Chaque export est une copie **complète**, pas un delta : le coût du bucket croît avec la rétention.
  Une règle de cycle de vie (transition Glacier) la complète bien.
- Le bucket doit être dans la même région que la zone du volume.
- La réimportation exige une taille entre 1 Go et 1 To.
