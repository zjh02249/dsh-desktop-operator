[CmdletBinding()]
param(
    [string]$RuntimePath = "",

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AppName,

    [string]$WindowTitle = "",

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ContactName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SearchAutomationId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$EditorAutomationId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SendAutomationId,

    [string]$SendAccessibleName = "",

    [switch]$AllowFirstResultFallback,

    [switch]$PrepareDraft,

    [string]$DraftText = "",

    [string]$SendConfirmation = "",

    [switch]$ResetSearchAfter,

    [string]$DiagnosticScreenshotPath = ""
)

$ErrorActionPreference = "Stop"
$pluginRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
if ([string]::IsNullOrWhiteSpace($RuntimePath)) {
    $RuntimePath = Join-Path $pluginRoot "runtime\bin\win32-x64\open-computer-use.exe"
}
$RuntimePath = [System.IO.Path]::GetFullPath($RuntimePath)
if (-not (Test-Path -LiteralPath $RuntimePath -PathType Leaf)) {
    throw "Windows runtime not found: $RuntimePath"
}
foreach ($requiredValue in @(
    @{ Name = "AppName"; Value = $AppName },
    @{ Name = "ContactName"; Value = $ContactName },
    @{ Name = "SearchAutomationId"; Value = $SearchAutomationId },
    @{ Name = "EditorAutomationId"; Value = $EditorAutomationId },
    @{ Name = "SendAutomationId"; Value = $SendAutomationId }
)) {
    if ([string]::IsNullOrWhiteSpace([string]$requiredValue.Value)) {
        throw "$($requiredValue.Name) must not be blank."
    }
}
$AppName = $AppName.Trim()
$ContactName = $ContactName.Trim()
$SearchAutomationId = $SearchAutomationId.Trim()
$EditorAutomationId = $EditorAutomationId.Trim()
$SendAutomationId = $SendAutomationId.Trim()
if (-not [string]::IsNullOrWhiteSpace($SendConfirmation) -and -not $PrepareDraft) {
    throw "SendConfirmation requires -PrepareDraft."
}
$requiredSendConfirmation = "SEND:${AppName}:$ContactName"
if (-not [string]::IsNullOrWhiteSpace($SendConfirmation) -and $SendConfirmation -cne $requiredSendConfirmation) {
    throw "SendConfirmation must exactly equal '$requiredSendConfirmation'."
}
if ([string]::IsNullOrWhiteSpace($DraftText)) {
    $DraftText = "DSH Desktop Operator v0.11 validation $([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"
}

$journalPath = Join-Path ([System.IO.Path]::GetTempPath()) ("dsh-desktop-operator-messaging-" + [guid]::NewGuid().ToString("N") + ".jsonl")
$mcpProcess = $null
$nextRequestID = 1
$window = $null
$mainWindow = $null
$originalDraft = $null
$draftChanged = $false
$sendExecuted = $false
$draftRestored = $false
$searchRestored = $false
$originalSearch = $null
$failure = $null
$result = $null
$runID = [guid]::NewGuid().ToString("N")

function Start-McpProcess {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:RuntimePath
    $startInfo.Arguments = "mcp"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.EnvironmentVariables["OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS"] = "1"
    $startInfo.EnvironmentVariables["OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK"] = "1"
    $startInfo.EnvironmentVariables["OPEN_COMPUTER_USE_WINDOWS_ACTION_JOURNAL_PATH"] = $script:journalPath
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Could not start MCP runtime" }
    return $process
}

function Invoke-McpRequest([string]$Method, $Params) {
    $requestID = $script:nextRequestID
    $script:nextRequestID++
    $request = [ordered]@{ jsonrpc = "2.0"; id = $requestID; method = $Method }
    if ($null -ne $Params) { $request.params = $Params }
    $json = ($request | ConvertTo-Json -Compress -Depth 30) + [Environment]::NewLine
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $script:mcpProcess.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $script:mcpProcess.StandardInput.BaseStream.Flush()
    $readTask = $script:mcpProcess.StandardOutput.ReadLineAsync()
    if (-not $readTask.Wait(30000)) {
        throw "MCP request timed out after 30 seconds: id=$requestID method=$Method"
    }
    $line = $readTask.Result
    if ([string]::IsNullOrWhiteSpace($line)) {
        throw "MCP runtime returned no response: id=$requestID method=$Method"
    }
    $response = $line | ConvertFrom-Json
    if ($null -ne $response.error) {
        throw "MCP request failed: $($response.error.message)"
    }
    return $response.result
}

function Invoke-ComputerUseTool([string]$Name, $Arguments) {
    return Invoke-McpRequest "tools/call" @{ name = $Name; arguments = $Arguments }
}

function Assert-ToolSuccess($Result, [string]$Name) {
    if ($null -eq $Result -or $Result.isError) {
        $message = if ($null -ne $Result.content) { $Result.content[0].text } else { "missing result" }
        throw "$Name failed: $message"
    }
}

function Get-Observation([string]$Purpose = "observe target messaging application") {
    $observed = Invoke-ComputerUseTool "get_window_state" @{
        window = $script:window
        text_limit = 5000
        max_tree_nodes = 3000
        max_tree_depth = 96
    }
    Assert-ToolSuccess $observed $Purpose
    $text = [string]$observed.content[0].text
    $match = [regex]::Match($text, "(?m)^ObservationID:\s*(?<value>\S+)\s*$")
    if (-not $match.Success) { throw "$Purpose did not return an ObservationID" }
    return [pscustomobject]@{
        ID = $match.Groups["value"].Value
        Text = $text
        ImageData = [string](@($observed.content | Where-Object { $_.type -eq "image" })[0].data)
    }
}

function Save-DiagnosticScreenshot($Observation, [string]$Suffix = "") {
    if ([string]::IsNullOrWhiteSpace($DiagnosticScreenshotPath) -or [string]::IsNullOrWhiteSpace($Observation.ImageData)) {
        return
    }
    $path = [System.IO.Path]::GetFullPath($DiagnosticScreenshotPath)
    if (-not [string]::IsNullOrWhiteSpace($Suffix)) {
        $path = [System.IO.Path]::Combine(
            [System.IO.Path]::GetDirectoryName($path),
            ([System.IO.Path]::GetFileNameWithoutExtension($path) + "-$Suffix" + [System.IO.Path]::GetExtension($path))
        )
    }
    $directory = [System.IO.Path]::GetDirectoryName($path)
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    [System.IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($Observation.ImageData))
}

function Get-ForegroundTargetWindow {
    $listed = Invoke-ComputerUseTool "list_windows" @{ app = $script:AppName }
    Assert-ToolSuccess $listed "list target application windows"
    try {
        $parsedWindows = $listed.content[0].text | ConvertFrom-Json -ErrorAction Stop
        $windows = @()
        foreach ($parsedWindow in $parsedWindows) {
            $windows += $parsedWindow
        }
    } catch {
        throw "Target application window list returned invalid JSON."
    }
    $foreground = @($windows | Where-Object { $_.isForeground -and $_.pid -eq $script:mainWindow.pid })
    if ($foreground.Count -ne 1) {
        throw "Could not resolve exactly one foreground target application window; found $($foreground.Count)."
    }
    $candidate = $foreground[0]
    if ([string]::IsNullOrWhiteSpace([string]$candidate.appId) -or
        [int]$candidate.pid -le 0 -or
        [string]::IsNullOrWhiteSpace([string]$candidate.hwnd) -or
        [string]::IsNullOrWhiteSpace([string]$candidate.generation)) {
        throw "Foreground target application WindowRef is incomplete: $($candidate | ConvertTo-Json -Compress -Depth 8)"
    }
    $script:window = [pscustomobject]@{
        appId = [string]$candidate.appId
        pid = [int]$candidate.pid
        hwnd = [string]$candidate.hwnd
        title = [string]$candidate.title
        generation = [string]$candidate.generation
        ownerHwnd = [string]$candidate.ownerHwnd
        isModal = [bool]$candidate.isModal
        isForeground = [bool]$candidate.isForeground
        isMinimized = [bool]$candidate.isMinimized
        processStarted = [string]$candidate.processStarted
    }
    return $script:window
}

function Use-MainWindow {
    if ($null -eq $script:mainWindow) { return }
    $script:window = $script:mainWindow
    $activated = Invoke-ComputerUseTool "activate_window" @{ window = $script:window }
    Assert-ToolSuccess $activated "activate target application main window"
}

function Get-StableSearchObservation {
    $lastError = $null
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        try {
            [void](Get-ForegroundTargetWindow)
            return Get-Observation "observe target application contact results"
        } catch {
            $lastError = $_
            Start-Sleep -Milliseconds 300
        }
    }
    throw $lastError
}

function Find-Elements($Observation, [hashtable]$Selectors, [string]$Purpose) {
    $arguments = @{
        window = $script:window
        observation_id = $Observation.ID
        limit = 100
    }
    foreach ($entry in $Selectors.GetEnumerator()) {
        $arguments[$entry.Key] = $entry.Value
    }
    $found = Invoke-ComputerUseTool "find_elements" $arguments
    Assert-ToolSuccess $found $Purpose
    try {
        return $found.content[0].text | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "$Purpose returned invalid JSON."
    }
}

function Get-SingleElement($SearchResult, [string]$Purpose, [scriptblock]$Predicate = $null) {
    $candidates = @($SearchResult.elements)
    if ($null -ne $Predicate) {
        $candidates = @($candidates | Where-Object $Predicate)
    }
    if ($candidates.Count -ne 1) {
        $names = @($candidates | ForEach-Object { "index=$($_.index),name=$($_.name),automationId=$($_.automationId)" }) -join "; "
        $allNames = @($SearchResult.elements | ForEach-Object { "index=$($_.index),name=$($_.name),automationId=$($_.automationId),enabled=$($_.isEnabled),offscreen=$($_.isOffscreen)" }) -join "; "
        throw "$Purpose requires exactly one semantic match; found $($candidates.Count). filtered=[$names] all=[$allNames]"
    }
    return $candidates[0]
}

function Set-ElementValue($Observation, $Element, [string]$Value, [string]$Purpose, [string]$ActionSuffix) {
    $setResult = Invoke-ComputerUseTool "set_value" @{
        window = $script:window
        observation_id = $Observation.ID
        element_index = [string]$Element.index
        value = $Value
        action_id = "messaging-$ActionSuffix-$script:runID"
        idempotency_key = "messaging-$ActionSuffix-$script:runID"
        action_intent = @{ kind = "edit"; summary = $Purpose }
        expected_postcondition = @{ type = "target_value_equals"; value = $Value }
    }
    Assert-ToolSuccess $setResult $Purpose
    if ([string]$setResult.content[0].text -notmatch "ActionStatus: applied") {
        throw "$Purpose did not report ActionStatus: applied"
    }
}

function Get-SearchElement($Observation) {
    $search = Find-Elements $Observation @{ automation_id = $script:SearchAutomationId; action = "SetValue" } "find target application search edit"
    return Get-SingleElement $search "target application search edit" { $_.automationId -ieq $script:SearchAutomationId -and -not $_.isOffscreen }
}

function Get-DraftElement($Observation) {
    $drafts = Find-Elements $Observation @{ automation_id = $script:EditorAutomationId; action = "SetValue" } "find target application message editor"
    return Get-SingleElement $drafts "target application message editor" { $_.automationId -ieq $script:EditorAutomationId -and $_.automationId -ine $script:SearchAutomationId -and -not $_.isOffscreen }
}

function Restore-DraftSafely {
    if (-not $script:draftChanged -or $script:sendExecuted -or $null -eq $script:originalDraft -or $null -eq $script:window) {
        return
    }
    $observation = Get-Observation "observe target application before restoring draft"
    $draft = Get-DraftElement $observation
    Set-ElementValue $observation $draft ([string]$script:originalDraft) "Restore the original target application draft" "restore-draft"
    $verify = Get-Observation "verify restored target application draft"
    $verifiedDraft = Get-DraftElement $verify
    if ([string]$verifiedDraft.value -cne [string]$script:originalDraft) {
        throw "Target application draft restoration verification failed."
    }
    $script:draftRestored = $true
    $script:draftChanged = $false
}

function Restore-SearchSafely {
    if ($null -eq $script:originalSearch -or $null -eq $script:window) { return }
    $observation = Get-Observation "observe target application before restoring search"
    $search = Get-SearchElement $observation
    if ([string]$search.value -cne [string]$script:originalSearch) {
        Set-ElementValue $observation $search ([string]$script:originalSearch) "Restore the original target application search value" "restore-search"
        $observation = Get-Observation "verify restored target application search"
        $search = Get-SearchElement $observation
    }
    if ([string]$search.value -cne [string]$script:originalSearch) {
        throw "Target application search restoration verification failed."
    }
    $script:searchRestored = $true
}

try {
    $mcpProcess = Start-McpProcess
    [void](Invoke-McpRequest "initialize" @{ protocolVersion = "2025-03-26"; capabilities = @{}; clientInfo = @{ name = "windows-messaging-smoke"; version = "1" } })

    $windowQuery = @{ app = $AppName }
    if (-not [string]::IsNullOrWhiteSpace($WindowTitle)) { $windowQuery.title = $WindowTitle }
    $resolved = Invoke-ComputerUseTool "get_window" $windowQuery
    Assert-ToolSuccess $resolved "get target application window"
    $window = $resolved.content[0].text | ConvertFrom-Json
    $mainWindow = $window

    $activated = Invoke-ComputerUseTool "activate_window" @{ window = $window }
    Assert-ToolSuccess $activated "activate target application"
    $initial = Get-Observation "observe target application"
    $searchElement = Get-SearchElement $initial

    if (-not $PrepareDraft) {
        $result = [pscustomobject]@{
            status = "passed"
            mode = "observe-only"
            app = $window.appId
            pid = $window.pid
            hwnd = $window.hwnd
            searchSemanticLookupVerified = $true
            draftPrepared = $false
            sendReady = $false
            sendExecuted = $false
        }
    } else {
        $originalSearch = [string]$searchElement.value
        if ($ResetSearchAfter) {
            $originalSearch = ""
        }
        Set-ElementValue $initial $searchElement $ContactName "Fill the target application contact search" "search"

        $searchObservation = Get-StableSearchObservation
        Save-DiagnosticScreenshot $searchObservation "results"
        $contactMatches = Find-Elements $searchObservation @{ name = $ContactName } "find exact target application contact"
        if ([int]$contactMatches.matchCount -eq 0) {
            $contactMatches = Find-Elements $searchObservation @{ value = $ContactName } "find exact target application contact value"
        }
        $exactContacts = @()
        foreach ($candidate in @($contactMatches.elements)) {
            if (($candidate.name -ceq $ContactName -or $candidate.value -ceq $ContactName) -and -not $candidate.isOffscreen -and $candidate.isEnabled -and $null -ne $candidate.frame) {
                $exactContacts += $candidate
            }
        }
        if ($exactContacts.Count -eq 1) {
            $contactElement = $exactContacts[0]
            $selectContact = Invoke-ComputerUseTool "click" @{
                window = $script:window
                observation_id = $searchObservation.ID
                element_index = [string]$contactElement.index
                click_method = "auto"
                action_id = "messaging-select-$runID"
                idempotency_key = "messaging-select-$runID"
                action_intent = @{ kind = "select"; summary = "Select the exact target application contact" }
                expected_postcondition = @{ type = "text_contains"; text = $ContactName }
            }
            Assert-ToolSuccess $selectContact "select exact target application contact"
            $selectionMethod = "semantic-exact-match"
        } elseif ($exactContacts.Count -eq 0 -and $AllowFirstResultFallback) {
            # This opt-in fallback is only for applications whose transient result
            # surface has no accessible children. The draft remains untouched until
            # the selected conversation identity is verified exactly.
            $selectContact = Invoke-ComputerUseTool "press_key" @{
                window = $script:window
                observation_id = $searchObservation.ID
                key = "Return"
                action_id = "messaging-select-top-$runID"
                idempotency_key = "messaging-select-top-$runID"
                action_intent = @{ kind = "select"; summary = "Select the first target application result before exact conversation verification" }
            }
            Assert-ToolSuccess $selectContact "select first target application search result"
            Start-Sleep -Milliseconds 1500
            $selectionMethod = "top-result-enter-then-verify"
        } else {
            throw "Target application search did not expose exactly one actionable contact; refusing to guess."
        }

        Use-MainWindow
        $conversation = Get-Observation "observe selected target application conversation"
        if ($conversation.Text -notmatch [regex]::Escape($ContactName)) {
            throw "Selected target application conversation did not expose the requested contact name."
        }
        $conversationContact = Find-Elements $conversation @{ name = $ContactName } "verify exact target application conversation"
        $exactConversationMatches = @($conversationContact.elements | Where-Object { $_.name -ceq $ContactName -and -not $_.isOffscreen })
        if ($exactConversationMatches.Count -lt 1) {
            throw "Selected target application conversation did not expose an exact accessible contact identity."
        }
        $draftElement = Get-DraftElement $conversation
        $originalDraft = [string]$draftElement.value
        Set-ElementValue $conversation $draftElement $DraftText "Prepare the target application draft" "prepare-draft"
        $draftChanged = $true

        $prepared = Get-Observation "verify prepared target application draft"
        $preparedDraft = Get-DraftElement $prepared
        if ([string]$preparedDraft.value -cne $DraftText) {
            throw "Prepared target application draft did not match the requested text."
        }
        $sendMatches = Find-Elements $prepared @{ automation_id = $SendAutomationId; action = "Invoke" } "find target application send button"
        $sendButton = Get-SingleElement $sendMatches "target application send button" {
            $_.automationId -ieq $script:SendAutomationId -and
                ([string]::IsNullOrWhiteSpace($script:SendAccessibleName) -or $_.name -ceq $script:SendAccessibleName) -and
                -not $_.isOffscreen
        }

        if ($SendConfirmation -ceq $requiredSendConfirmation) {
            $send = Invoke-ComputerUseTool "click" @{
                window = $window
                observation_id = $prepared.ID
                element_index = [string]$sendButton.index
                click_method = "accessibility"
                action_id = "messaging-send-$runID"
                idempotency_key = "messaging-send-$runID"
                action_intent = @{ kind = "send"; summary = "Send the explicitly confirmed target application draft" }
                expected_postcondition = @{ type = "screenshot_changed" }
            }
            Assert-ToolSuccess $send "send confirmed target application message"
            $sendExecuted = $true
            $draftChanged = $false
        } else {
            Restore-DraftSafely
        }
        Restore-SearchSafely

        $result = [pscustomobject]@{
            status = "passed"
            mode = if ($sendExecuted) { "explicit-send" } else { "prepare-and-restore" }
            app = $window.appId
            pid = $window.pid
            hwnd = $window.hwnd
            contactExactMatchVerified = $true
            contactSelectionMethod = $selectionMethod
            searchSemanticLookupVerified = $true
            messageEditorSemanticLookupVerified = $true
            draftPrepared = $true
            draftLength = $DraftText.Length
            sendButtonSemanticLookupVerified = $true
            sendReady = $true
            sendExecuted = $sendExecuted
            draftRestored = $draftRestored
            searchRestored = $searchRestored
        }
    }
} catch {
    $failure = $_
} finally {
    try { Use-MainWindow } catch { if ($null -eq $failure) { $failure = $_ } }
    if (-not $sendExecuted) {
        try { Restore-DraftSafely } catch { if ($null -eq $failure) { $failure = $_ } }
    }
    try { Restore-SearchSafely } catch { if ($null -eq $failure) { $failure = $_ } }
    if ($null -ne $mcpProcess -and -not $mcpProcess.HasExited) {
        try { $mcpProcess.StandardInput.Close() } catch {}
        if (-not $mcpProcess.WaitForExit(1000)) { $mcpProcess.Kill() }
    }
    if (Test-Path -LiteralPath $journalPath) {
        Remove-Item -LiteralPath $journalPath -Force
    }
}

if ($null -ne $failure) { throw $failure }
$result | ConvertTo-Json -Depth 8
