/**
 * Runs a one-off Job from a CronJob and waits for it to complete.
 *
 * Usage: NAMESPACE=reporting CRONJOB_NAME=test-cronjob npm run trigger-cronjob
 */
import { BatchV1Api, KubeConfig } from '@kubernetes/client-node';

const NAMESPACE = process.env.NAMESPACE ?? 'reporting';
const CRONJOB_NAME = process.env.CRONJOB_NAME ?? 'test-cronjob';
const JOB_NAME = `${CRONJOB_NAME}-manual-${Math.floor(Date.now() / 1000)}`;

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const kc = new KubeConfig();
kc.loadFromDefault();
const batchApi = kc.makeApiClient(BatchV1Api);

console.log(`--> Creating job ${JOB_NAME} from cronjob/${CRONJOB_NAME}...`);
const { body: cronJob } = await batchApi.readNamespacedCronJob(CRONJOB_NAME, NAMESPACE);
await batchApi.createNamespacedJob(NAMESPACE, {
  metadata: { name: JOB_NAME, namespace: NAMESPACE },
  spec: cronJob.spec!.jobTemplate.spec,
});

console.log(`--> Waiting for job ${JOB_NAME} to complete...`);
while (true) {
  const { body: job } = await batchApi.readNamespacedJob(JOB_NAME, NAMESPACE);
  const conditions = job.status?.conditions ?? [];

  if (conditions.some((c) => c.type === 'Complete' && c.status === 'True')) {
    console.log(`--> SUCCESS: Job ${JOB_NAME} completed successfully.`);
    process.exit(0);
  }
  if (conditions.some((c) => c.type === 'Failed' && c.status === 'True')) {
    console.error(`--> ERROR: Job ${JOB_NAME} failed.`);
    process.exit(1);
  }

  await sleep(2000);
}
