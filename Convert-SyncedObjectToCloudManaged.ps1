[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param()

$ErrorActionPreference = 'Stop'

$moduleName = 'Microsoft.Graph.Authentication'
$module = Get-Module -ListAvailable -Name $moduleName | Select-Object -First 1
if (-not $module) {
    $installAnswer = Read-Host "$moduleName モジュールがありません。現在のユーザーにインストールしますか? (Y/N)"
    if ($installAnswer -notmatch '^(Y|Yes)$') {
        throw 'Graph モジュールが必要なため処理を終了します。'
    }

    try {
        Install-Module -Name $moduleName -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop
    }
    catch {
        throw "Graph モジュールをインストールできませんでした: $($_.Exception.Message)"
    }
}

Import-Module $moduleName -ErrorAction Stop

Write-Host '対象のオブジェクト種別を選択してください:'
Write-Host '  1. ユーザー'
Write-Host '  2. グループ'
$objectChoice = Read-Host '番号'
switch ($objectChoice) {
    '1' {
        $objectType = 'User'
        $collectionPath = 'users'
        $apiVersion = 'v1.0'
        $scopes = @('User.Read.All', 'User-OnPremisesSyncBehavior.ReadWrite.All')
        $select = 'id,displayName,userPrincipalName,mail,onPremisesSyncEnabled'
    }
    '2' {
        $objectType = 'Group'
        $collectionPath = 'groups'
        $apiVersion = 'beta'
        $scopes = @('Group.Read.All', 'Group-OnPremisesSyncBehavior.ReadWrite.All')
        $select = 'id,displayName,mail,mailNickname,onPremisesSyncEnabled'
        Write-Warning 'グループのSOA APIはMicrosoft Graph betaです。ベータAPIは変更される可能性があり、本番利用はサポートされていません。'
    }
    default {
        throw '対象の選択が正しくありません。1 または 2 を指定してください。'
    }
}

Connect-MgGraph -Scopes $scopes -ContextScope Process -NoWelcome -ErrorAction Stop
$graphContext = Get-MgContext
if (-not $graphContext -or @($graphContext.Scopes) -notcontains $scopes[-1]) {
    throw "必要なGraph委任アクセス許可 '$($scopes[-1])' がトークンにありません。管理者の同意を確認してから再実行してください。"
}

function Invoke-GraphRequest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'PATCH')]
        [string] $Method,

        [Parameter(Mandatory)]
        [string] $Uri,

        [hashtable] $Body
    )

    $requestParameters = @{
        Method      = $Method
        Uri         = $Uri
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $requestParameters.Body = $Body
        $requestParameters.ContentType = 'application/json'
    }

    Invoke-MgGraphRequest @requestParameters
}

function Get-GraphCollection {
    param(
        [Parameter(Mandatory)]
        [string] $Uri
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $nextUri = $Uri
    while ($nextUri) {
        $page = Invoke-GraphRequest -Method GET -Uri $nextUri
        foreach ($item in $page.value) {
            $items.Add($item)
        }
        $nextUri = $page.'@odata.nextLink'
    }

    $items.ToArray()
}

function Protect-CsvText {
    param([AllowNull()][string] $Value)

    if ($null -ne $Value -and $Value.TrimStart() -match '^[=+\-@]') {
        return "'$Value"
    }
    $Value
}

$collectionUri = "https://graph.microsoft.com/$apiVersion/$collectionPath`?`$select=$select&`$top=999"
Write-Host "$objectType をMicrosoft Entra IDから取得しています..."
$directoryObjects = @(Get-GraphCollection -Uri $collectionUri)
$syncedObjects = @($directoryObjects | Where-Object { $_.onPremisesSyncEnabled -eq $true })
if ($syncedObjects.Count -eq 0) {
    Write-Host 'AD同期中の対象は見つかりませんでした。'
    return
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$csvPath = Join-Path (Get-Location).Path "Entra-SOA-$($objectType)s-$timestamp.csv"
$csvRows = foreach ($object in $syncedObjects) {
    [pscustomobject]@{
        Id                       = $object.id
        ObjectType               = $objectType
        DisplayName              = Protect-CsvText -Value $object.displayName
        UserPrincipalName        = Protect-CsvText -Value $object.userPrincipalName
        Mail                     = Protect-CsvText -Value $object.mail
        OnPremisesSyncEnabled    = $object.onPremisesSyncEnabled
    }
}
$csvRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "$($syncedObjects.Count) 件をCSVに出力しました: $csvPath"
Write-Host 'CSVから変換対象以外の行を削除し、保存してください。ID列とObjectType列は変更しないでください。'

$editedCsvPath = Read-Host '編集したCSVのパスを入力してください (空欄で上記CSVを使用)'
if ([string]::IsNullOrWhiteSpace($editedCsvPath)) {
    $editedCsvPath = $csvPath
}
if (-not (Test-Path -LiteralPath $editedCsvPath -PathType Leaf)) {
    throw "CSVファイルが見つかりません: $editedCsvPath"
}

$selectedRows = @(Import-Csv -LiteralPath $editedCsvPath -Encoding UTF8)
if ($selectedRows.Count -eq 0) {
    throw 'CSVに対象行がありません。変換対象を1件以上残してから再実行してください。'
}
if ($selectedRows[0].PSObject.Properties.Name -notcontains 'Id' -or
    $selectedRows[0].PSObject.Properties.Name -notcontains 'ObjectType') {
    throw 'CSVに Id 列または ObjectType 列がありません。エクスポートしたCSVを使用してください。'
}

$selectedIds = [System.Collections.Generic.List[string]]::new()
$uniqueIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($row in $selectedRows) {
    if ($row.ObjectType -ne $objectType) {
        throw "CSVのObjectTypeが選択した種別 '$objectType' と一致しません: $($row.ObjectType)"
    }
    $parsedId = [guid]::Empty
    if (-not [guid]::TryParse([string]$row.Id, [ref]$parsedId)) {
        throw "CSVに無効なIDがあります: $($row.Id)"
    }
    $normalizedId = $parsedId.ToString()
    if (-not $uniqueIds.Add($normalizedId)) {
        throw "CSVに同じIDが複数回あります: $normalizedId"
    }
    $selectedIds.Add($normalizedId)
}

$validatedObjects = [System.Collections.Generic.List[object]]::new()
foreach ($id in $selectedIds) {
    $objectUri = "https://graph.microsoft.com/$apiVersion/$collectionPath/$id`?`$select=id,displayName,onPremisesSyncEnabled"
    $behaviorUri = "https://graph.microsoft.com/$apiVersion/$collectionPath/$id/onPremisesSyncBehavior"
    $currentObject = Invoke-GraphRequest -Method GET -Uri $objectUri
    if ($currentObject.onPremisesSyncEnabled -ne $true) {
        throw "現在AD同期中ではないため、CSV全体を中止します: $($currentObject.displayName) ($id)"
    }

    $behavior = Invoke-GraphRequest -Method GET -Uri $behaviorUri
    if ($behavior.isCloudManaged -ne $false) {
        throw "現在のSOAがAD管理であることを確認できないため、CSV全体を中止します: $($currentObject.displayName) ($id)"
    }
    $validatedObjects.Add($currentObject)
}

Write-Host ''
Write-Host "変換対象: $($validatedObjects.Count) 件 ($objectType)"
$validatedObjects | Select-Object -First 20 | ForEach-Object {
    Write-Host "  $($_.displayName) [$($_.id)]"
}
if ($validatedObjects.Count -gt 20) {
    Write-Host "  ...ほか $($validatedObjects.Count - 20) 件"
}
Write-Warning 'この操作でSOAをEntra ID管理に変更します。ADアカウント自体を削除する操作ではありません。'
$confirmation = Read-Host "実行するには TRANSFER と入力してください"
if ($confirmation -cne 'TRANSFER') {
    Write-Host '確認されなかったため、変換を行いませんでした。'
    return
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($object in $validatedObjects) {
    $status = 'Failed'
    $message = ''
    $target = "$($object.displayName) ($($object.id))"
    if ($PSCmdlet.ShouldProcess($target, 'SOAをEntra ID管理に変更')) {
        try {
            $objectUri = "https://graph.microsoft.com/$apiVersion/$collectionPath/$($object.id)`?`$select=id,displayName,onPremisesSyncEnabled"
            $behaviorUri = "https://graph.microsoft.com/$apiVersion/$collectionPath/$($object.id)/onPremisesSyncBehavior"
            $currentObject = Invoke-GraphRequest -Method GET -Uri $objectUri
            $currentBehavior = Invoke-GraphRequest -Method GET -Uri $behaviorUri
            if ($currentObject.onPremisesSyncEnabled -ne $true -or $currentBehavior.isCloudManaged -ne $false) {
                throw '実行直前の再確認で、AD同期中かつAD管理であることを確認できませんでした。'
            }

            Invoke-GraphRequest -Method PATCH -Uri $behaviorUri -Body @{ isCloudManaged = $true } | Out-Null
            $status = 'Succeeded'
            $message = 'isCloudManaged を true に設定しました。'
        }
        catch {
            $message = $_.Exception.Message
            Write-Warning "変換に失敗しました: $target - $message"
        }
    }
    else {
        $status = 'WhatIf'
        $message = 'WhatIfまたはShouldProcessにより変更していません。'
    }

    $results.Add([pscustomobject]@{
        Id          = $object.id
        ObjectType  = $objectType
        DisplayName = $object.displayName
        Status      = $status
        Message     = $message
    })
}

$resultPath = Join-Path (Get-Location).Path "Entra-SOA-Results-$timestamp.csv"
$results | Export-Csv -LiteralPath $resultPath -NoTypeInformation -Encoding UTF8
$succeededCount = @($results | Where-Object { $_.Status -eq 'Succeeded' }).Count
$failedCount = @($results | Where-Object { $_.Status -eq 'Failed' }).Count
Write-Host "処理結果: 成功 $succeededCount 件 / 失敗 $failedCount 件"
Write-Host "結果CSV: $resultPath"
if ($failedCount -gt 0) {
    throw "$failedCount 件の変換に失敗しました。結果CSVを確認してください。"
}
