$ErrorActionPreference = "SilentlyContinue"

$storageAccounts = @()
$now = Get-Date

# Get a list of all storage accounts using Azure Resource Graph as it's more performant
# than using Get-AzResource or Get-AzStorageAccount.
$kqlQuery = @"
resources
| where type =~ "Microsoft.Storage/storageAccounts"
| project id
"@

# Resource Graph has a limit on the number of results it will return, so we will
# need to work our way through a set of paginated responses
$batchSize  = 99
$skipResult = 0
[System.Collections.Generic.List[string]]$storageIds
$PSDefaultParameterValues=@{"Search-AzGraph:Subscription"= $(Get-AzSubscription).ID}
while ($true) {
  if ($skipResult -gt 0) {
    $graphResult = Search-AzGraph -UseTenantScope -Query $kqlQuery -First $batchSize -SkipToken $graphResult.SkipToken
  }
  else {
    $graphResult = Search-AzGraph -UseTenantScope -Query $kqlQuery -First $batchSize
  }

  $storageIds += $graphResult.data

  if ($graphResult.data.Count -lt $batchSize) {
    break;
  }
  $skipResult += $skipResult + $batchSize
}

$storageIds = $storageIds | Select-Object -ExpandProperty id

$storageIds | ForEach-Object {
    
    # Get a reference to the storage account and the context
    $resource = Get-AzResource -ResourceId $_
    $blobServiceId = $resource.Id + "/blobServices/default"
    
    # Set dimension filters for hot and cool access tiers
    $hotFilter     = New-AzMetricFilter -Dimension Tier -Operator eq -Value "Hot"
    $coolFilter    = New-AzMetricFilter -Dimension Tier -Operator eq -Value "Cool"
    $coldFilter    = New-AzMetricFilter -Dimension Tier -Operator eq -Value "Cold"
    $archiveFilter = New-AzMetricFilter -Dimension Tier -Operator eq -Value "Archive"
    
    # Get the average blob capacity of the hot and cool access tiers
    $hotTierMetric     = Get-AzMetric -ResourceId $blobServiceId -MetricName "BlobCapacity" -StartTime ($now.AddDays(-1)) -EndTime $now -TimeGrain 01:00:00 -MetricFilter $hotFilter 
    $coolTierMetric    = Get-AzMetric -ResourceId $blobServiceId -MetricName "BlobCapacity" -StartTime ($now.AddDays(-1)) -EndTime $now -TimeGrain 01:00:00 -MetricFilter $coolFilter
    $coldTierMetric    = Get-AzMetric -ResourceId $blobServiceId -MetricName "BlobCapacity" -StartTime ($now.AddDays(-1)) -EndTime $now -TimeGrain 01:00:00 -MetricFilter $coldFilter
    $archiveTierMetric = Get-AzMetric -ResourceId $blobServiceId -MetricName "BlobCapacity" -StartTime ($now.AddDays(-1)) -EndTime $now -TimeGrain 01:00:00 -MetricFilter $archiveFilter
    
    $hotTierSize     = $hotTierMetric.Data.Average     | Measure-Object -Average | Select-Object -ExpandProperty Average
    $coolTierSize    = $coolTierMetric.Data.Average    | Measure-Object -Average | Select-Object -ExpandProperty Average
    $coldTierSize    = $coldTierMetric.Data.Average    | Measure-Object -Average | Select-Object -ExpandProperty Average
    $archiveTierSize = $archiveTierMetric.Data.Average | Measure-Object -Average | Select-Object -ExpandProperty Average
    
    $storageAccounts += [ordered]@{
        StorageAccountName = $resource.Name
        Sku                = $resource.Sku.Name
        Region             = $resource.Location
        CostCenter         = $resource.Tags.CostCenter
        Tier               = "Hot"
        Capacity           = [System.Math]::Round($hotTierSize / 1Gb, 3)
    }
    $storageAccounts += [ordered]@{
        StorageAccountName = $resource.Name
        Sku                = $resource.Sku.Name
        Region             = $resource.Location
        CostCenter         = $resource.Tags.CostCenter
        Tier               = "Cool"
        Capacity           = [System.Math]::Round($coolTierSize / 1Gb, 3)
    } 
    $storageAccounts += [ordered]@{
        StorageAccountName = $resource.Name
        Sku                = $resource.Sku.Name
        Region             = $resource.Location
        CostCenter         = $resource.Tags.CostCenter
        Tier               = "Cold"
        Capacity           = [System.Math]::Round($coldTierSize / 1Gb, 3)
    } 
    $storageAccounts += [ordered]@{
        StorageAccountName = $resource.Name
        Sku                = $resource.Sku.Name
        Region             = $resource.Location
        CostCenter         = $resource.Tags.CostCenter
        Tier               = "Archive"
        Capacity           = [System.Math]::Round($archiveTierSize / 1Gb, 3)
    }               
}

$exportFilePath = "$($PSScriptRoot)/storage-stats.csv"
Remove-Item -Path $exportFilePath -ErrorAction SilentlyContinue
$storageAccounts | Export-Csv -NoTypeInformation -Path $exportFilePath
