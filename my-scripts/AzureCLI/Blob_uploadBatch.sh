container="\$web"
storageAccountName="sekhanvdemo"
source="/Users/sekhanov/Projects/tmp/agro-angular-daily-feed-calc/docs"

az storage blob upload-batch --destination $container --account-name "$storageAccountName" --source "$source"