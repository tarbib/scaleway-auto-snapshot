# Automatic snapshot tool for Scaleway

Serverless Job on Scaleway: snapshot of an Instance volume (l_ssd or b_ssd), export to QCOW2 to an
Object Storage bucket, snapshot deletion, then retention of the N most recent exports.

Image: `ghcr.io/tarbib/scaleway-auto-snapshot:latest`

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `SCW_ACCESS_KEY` | — | IAM API key |
| `SCW_SECRET_KEY` | — | IAM secret key |
| `SCW_DEFAULT_PROJECT_ID` | — | target project |
| `VOLUME_ID` | — | volume UUID |
| `BUCKET` | — | destination bucket, **same region as the volume** |
| `ZONE` | `fr-par-1` | volume zone |
| `RETENTION` | `3` | number of `.qcow2` exports kept in the bucket |
| `PREFIX` | `snapshots` | key root: `<PREFIX>/<instance>/autosnap-<date>.qcow2` |
| `LABEL` | instance name | forces the folder name |
| `EXPORT_TIMEOUT` | `7200` | export timeout, in seconds |

The folder is named after the instance the volume is attached to; if the instance is
renamed, a new folder appears and retention starts over from zero in it.

## Job IAM permissions

`InstancesFullAccess` + `ObjectStorageFullAccess`, on the relevant project.

## Create the job

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

Pass API keys via Secret Manager rather than as plain-text environment variables.

## Restore

From the console: Object Storage > the bucket > object menu > **Import as snapshot**,
choosing Local Storage or Block SSD type. Then create an Instance from that snapshot.

Via CLI:

```sh
scw instance snapshot create name=restore volume-type=l_ssd \
  bucket=<bucket> key=snapshots/<instance>/autosnap-20260821-020000.qcow2 zone=fr-par-2
```

## Notes

- Each export is a **full** copy, not a delta: bucket cost grows with retention.
  A lifecycle rule (Glacier transition) complements this well.
- The bucket must be in the same region as the volume's zone.
- Reimport requires a size between 1 GB and 1 TB.
