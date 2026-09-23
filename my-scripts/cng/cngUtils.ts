enum Environment {
    PROD = "prod",
    SANDBOX = "sandbox",
    DEV = "dev",
    QA = "qa",
}

enum AzureRegion {
    US = "eastus",
    EU = "westeurope",
    CA = "canadacentral",
    APAC = "australiaeast",
}

function getKeyVaultName(env: Environment, region: AzureRegion): string {
    switch (env) {
        case Environment.PROD:
            switch (region) {
                case AzureRegion.US: return "reportingf19bkxbavygtwbq";
                case AzureRegion.EU: return "reportingi74p3ek4zha86ag";
                case AzureRegion.CA: return "reportingtzes3p9uey6faty";
                case AzureRegion.APAC: return "reportingq8t9y5g1d8t7jmu";
            }
            break;
        case Environment.SANDBOX:
            switch (region) {
                case AzureRegion.US: return "reporting77schkc8md2p2i5";
                case AzureRegion.EU: return "reportingttbbdwyjy325gwr";
                case AzureRegion.CA: return "reporting7nv1rtj49mbnp8o";
                case AzureRegion.APAC: return "reportinge02fphixi1ei22h";
            }
            break;
        case Environment.DEV:
            switch (region) {
                case AzureRegion.US: return "reporting13bjqz1801fzkoi";
            }
        case Environment.DEV:
            switch (region) {
                case AzureRegion.US: return "reporting13bjqz1801fzkoi";
            }
        case Environment.QA:
            switch (region) {
                case AzureRegion.US: return "reportingl0zm0nnywuu9swv";
            }
    }
    throw new Error(`No key vault name found for env=${env}, region=${region}`);
}

function printReportingDbCredentials(env: Environment, region: AzureRegion, tenantId: string): void {
    const vaultName = getKeyVaultName(env, region);
    console.log(`${region}-${env}-${tenantId}:`);
    console.log(`az keyvault secret show --query value --vault-name ${vaultName} --name ${env}-${tenantId}-reporting-dbname`);
    console.log(`az keyvault secret show --query value --vault-name ${vaultName} --name ${env}-${tenantId}-reporting-host`);
    console.log(`az keyvault secret show --query value --vault-name ${vaultName} --name ${env}-${tenantId}-reporting-password`);
    console.log(`az keyvault secret show --query value --vault-name ${vaultName} --name ${env}-${tenantId}-reporting-port`);
    console.log(`az keyvault secret show --query value --vault-name ${vaultName} --name ${env}-${tenantId}-reporting-user`);
}

function printSisenseCredentials(env: Environment, region: AzureRegion): void {
    const vaultName = getKeyVaultName(env, region);
    console.log(`az keyvault secret show --query value --vault-name ${vaultName} --name reporting-${env}-${region}-sisense-clusters-default-user`);
    console.log(`az keyvault secret show --query value --vault-name ${vaultName} --name reporting-${env}-${region}-sisense-clusters-default-password`);
}

function updateAvailabilityTestsCredentials(env: Environment, region: AzureRegion): void {
    const vaultName = getKeyVaultName(env, region);
    console.log(`${region}-${env}:`);
    console.log(`az keyvault secret set --vault-name ${vaultName} --name reporting-${env}-${region}-availability-tests-email --value reporting-availability-tests@mail-to-s3-open.intapp.com`);
    console.log(`az keyvault secret set --vault-name ${vaultName} --name reporting-${env}-${region}-availability-tests-password --value <PASSWORD_VALUE>`);
}
// printReportingDbCredentials(Environment.SANDBOX, AzureRegion.EU, "d62a17c80");
// printSisenseCredentials(Environment.PROD, AzureRegion.APAC);
// updateAvailabilityTestsCredentials(Environment.DEV, AzureRegion.US);

printReportingDbCredentials(Environment.PROD, AzureRegion.US, "7759b027b");
printReportingDbCredentials(Environment.PROD, AzureRegion.US, "7ca803dd6");
