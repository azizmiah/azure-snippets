# Queries for VM + VMSS instances
$vmInstanceQueries = @'
resources
| where type =~ "microsoft.compute/virtualMachines"
| where properties.extended.instanceView.powerState.displayStatus contains "running"
| extend skuName = properties.hardwareProfile.vmSize, count=toint(1)
| join kind=leftouter (
  resourcecontainers
    | where ['type'] =~ "microsoft.resources/subscriptions"
    | project id, name, subscriptionId
) on $left.subscriptionId == $right.subscriptionId
| project-rename subscriptionName=name1
| project subscriptionName, resourceGroup, location, name, skuName, ['count'], type
'@

$vmssIstanceQueries = @'
resources
| where type =~ "microsoft.compute/virtualMachineScaleSets"
| where properties.orchestrationMode !~ "flexible"
| extend skuName = sku.name, count=toint(sku.capacity)
| join kind=leftouter (
  resourcecontainers
    | where ['type'] =~ "microsoft.resources/subscriptions"
    | project id, name, subscriptionId
) on $left.subscriptionId == $right.subscriptionId
| project-rename subscriptionName=name1
| project subscriptionName, resourceGroup, location, name, skuName, ['count'], type
'@

# Paginate through VM results
$batchSize = 1000
$skipResult = 0
$vmResults = @()
while ($true) {
  if ($skipResult -gt 0) {
    $graphResult = Search-AzGraph -Query $vmInstanceQueries -First $batchSize -SkipToken $graphResult.SkipToken
  }
  else {
    $graphResult = Search-AzGraph -Query $vmInstanceQueries -First $batchSize
  }

  $vmResults += $graphResult.data

  if ($graphResult.data.Count -lt $batchSize) {
    break;
  }
  $skipResult += $skipResult + $batchSize
}

# Paginate through VMSS results
$batchSize = 1000
$skipResult = 0
$vmssResults = @()
while ($true) {
  if ($skipResult -gt 0) {
    $graphResult = Search-AzGraph -Query $vmssIstanceQueries -First $batchSize -SkipToken $graphResult.SkipToken
  }
  else {
    $graphResult = Search-AzGraph -Query $vmssIstanceQueries -First $batchSize
  }

  $vmssResults += $graphResult.data

  if ($graphResult.data.Count -lt $batchSize) {
    break;
  }
  $skipResult += $skipResult + $batchSize
}

# Download ISFR reference data
$referenceDataPath = "$((Get-Item -LiteralPath $env:TEMP).FullName)/flex-ratios.csv"
Remove-Item -Force -Path $referenceDataPath -ErrorAction SilentlyContinue
Invoke-WebRequest -Uri "https://aka.ms/isf" -OutFile $referenceDataPath
$isfrData = Import-Csv -Path $referenceDataPath

# Append ISFR data to KQL results
$kqlResults = $vmResults + $vmssResults
$counter = 0
foreach ($kqlResult in $kqlResults) {

  # Setup progress bar
  $counter++
  Write-Progress -Activity "Enriching KQL data with ISFR reference data" -CurrentOperation $kqlResult -PercentComplete ($counter / $kqlResults.Count * 100)

  # Find the matching row in the ISFR reference data CSV
  $referenceRow = $isfrData | Where-Object { $_.ArmSkuName -eq $kqlResult.skuName }

  if ($referenceRow) {
    # Extract InstanceSizeFlexibilityGroup and Ratio
    $instanceSizeFlexibilityGroup = $referenceRow.InstanceSizeFlexibilityGroup
    $ratio = $referenceRow.Ratio

    # Find the SKU within the InstanceSizeFlexibilityGroup where Ratio is 1
    $rowWithRatio1 = $isfrData | Where-Object {
      $_.InstanceSizeFlexibilityGroup -eq $instanceSizeFlexibilityGroup -and
      $_.Ratio -eq 1
    }
    $lowestCommonSku = $rowWithRatio1.ArmSkuName

    $lowestCommonSkuCount = $kqlResult.count * $ratio

    $kqlResult | Add-Member -Force -MemberType NoteProperty -Name "InstanceSizeFlexibilityGroup" -Value $instanceSizeFlexibilityGroup
    $kqlResult | Add-Member -Force -MemberType NoteProperty -Name "Ratio" -Value $ratio
    $kqlResult | Add-Member -Force -MemberType NoteProperty -Name "LowestCommonSku" -Value $lowestCommonSku
    $kqlResult | Add-Member -Force -MemberType NoteProperty -Name "LowestCommonSkuCount" -Value $lowestCommonSkuCount
  }
}

# Save the enriched data to CSV
$kqlResultsFilePath = "$($PSScriptRoot)/compute-isfr-stats.csv"
Remove-Item -Force -Path $kqlResultsFilePath -ErrorAction SilentlyContinue
$kqlResults | Export-Csv -NoTypeInformation -Path $kqlResultsFilePath
