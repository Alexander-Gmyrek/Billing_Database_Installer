# install.ps1

# Load configuration
$config = Get-Content .\config.txt | ConvertFrom-StringData

# Helper function to log messages
function Write-Message {
    param (
        [string]$message
    )
    Write-Output "$((Get-Date).ToString()): $message"
}

# Helper function to check if a path exists, if not execute the provided function
function Invoke-Install {
    param (
        [string]$path,
        [scriptblock]$installFunction
    )
    if (Test-Path $path) {
        Write-Message "Path already exists: $path"
    } else {
        & $installFunction
    }
}

# Ensure required directories and clone repositories
Invoke-Install -path $config.billingDatabasePath {
    New-Item -ItemType Directory -Path $config.billingDatabasePath
}

Invoke-Install -path "$($config.billingDatabasePath)\BillingDatabaseFiles" {
    git clone $config.billingDatabaseRepository "$($config.billingDatabasePath)\BillingDatabaseFiles"
}

Invoke-Install -path "$($config.billingDatabasePath)\Automations" {
    git clone $config.automationRepository "$($config.billingDatabasePath)\Automations"
}

Invoke-Install -path "$($config.billingDatabasePath)\Backup" {
    New-Item -ItemType Directory -Path "$($config.billingDatabasePath)\Backup"
}

# Install Docker
function Install-Docker {
    $dockerInstaller = "$env:TEMP\DockerInstaller.exe"
    Invoke-WebRequest -Uri "https://download.docker.com/win/stable/Docker%20Desktop%20Installer.exe" -OutFile $dockerInstaller
    Start-Process -FilePath $dockerInstaller -ArgumentList "/install", "/quiet" -Wait
    Remove-Item -Path $dockerInstaller
}
Invoke-Install -path "C:\Program Files\Docker" -installFunction { Install-Docker }

# Function to check if ports are open and replace them if necessary
function Confirm-Ports {
    param (
        [int[]]$ports,
        [int[]]$substitutePorts
    )
    $openPorts = @()
    foreach ($port in $ports) {
        $tcpConnections = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
        if ($tcpConnections) {
            Write-Message "Port $port is occupied."
        } else {
            $openPorts += $port
        }
    }

    if ($openPorts.Count -lt $ports.Count) {
        foreach ($port in $substitutePorts) {
            if ($openPorts.Count -eq $ports.Count) {
                break
            }
            $tcpConnections = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
            if (-not $tcpConnections) {
                $openPorts += $port
            }
        }
    }
    # Modifying this so that it doesn't auto kill the process feel free to modify this to your needs
    if ($openPorts.Count -lt $ports.Count) {
        $occupiedPorts = $ports | Where-Object { $_ -notin $openPorts }
        foreach ($port in $occupiedPorts) {
            if($openPorts.Count -lt $ports.Count) {
                $tcpConnections = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
                if ($tcpConnections) {
                    $processId = $tcpConnections.OwningProcess
                    $answer = read-host "Port $port is occupied by process with ID $processId. Do you want to stop the process? (Y/N)"
                    if ($answer -eq 'yes') { 
                        $process = Get-Process -Id $processId
                        $process | Stop-Process -Force
                        Write-Message "Stopped process using port $port (Process ID: $processId)"
                        $openPorts += $port
                    }  
                }
            }
        }
    }

    return $openPorts
}

# Check if required ports are open
$requiredPorts = [int[]]$config.portsToCheck
$substitutePorts = [int[]]$config.substitutePorts
$openPorts = Confirm-Ports -ports $requiredPorts -substitutePorts $substitutePorts
if ($openPorts.Count -lt $requiredPorts.Count) {
    throw "Unable to open required ports."
}


# Make sure the ports are ordered correcty to avoid unnecessary changes in docker-compose.yml
function Switch-OpenPorts {
    param (
        [int[]]$openPorts,
        [int[]]$requiredPorts
    )

    $n = $openPorts.Length
    if ($n -ne $requiredPorts.Length -or $n -le 1) {
        throw "Both arrays must have the same length greater than 1"
    }

    for ($i = 0; $i -lt $n; $i++) {
        for ($j = 0; $j -lt $n; $j++) {
            if ($openPorts[$i] -eq $requiredPorts[$j]) {
                $temp = $openPorts[$i]
                $openPorts[$i] = $openPorts[$j]
                $openPorts[$j] = $temp
            }
        }
    }
    
    return $openPorts
}

$openPorts = Switch-OpenPorts -openPorts $openPorts -requiredPorts $requiredPorts

# If Ports have changed, process each line and replace ports as needed
if ($openPorts -ne $requiredPorts) {
    # Update ports in the docker-compose.yml
    $dockerComposePath = "$($config.billingDatabasePath)\BillingDatabaseFiles\docker-compose.yml"
    $dockerCompose = Get-Content $dockerComposePath

    # Define the port pattern
    $portPattern = '(\d+):\d+'

    $portIndex = 0
    function Switch-ReplacePorts {
        param (
            [string]$line,
            [int[]]$newPorts,
            [ref]$portIndex,
            [string]$portPattern
        )

        if ($line -match $portPattern -and $portIndex.Value -lt $newPorts.Length) {
            $newPort = $newPorts[$portIndex.Value]
            $portIndex.Value++
            return $line -replace $portPattern, "${newPort}:$newPort"
        } else {
            return $line
        }
    }



    $updatedDockerCompose = $dockerCompose | ForEach-Object {
        Switch-ReplacePorts -line $_ -newPorts $openports -portIndex ([ref]$portIndex) -portPattern $portPattern
    }

    # Write the updated content back to the docker-compose.yml file
    $updatedDockerCompose | Set-Content $dockerComposePath

    Write-Output "Port numbers have been successfully updated in $dockerComposePath"

    if($openPorts[0] -ne $requiredPorts[0] -or $openPorts[1] -ne $requiredPorts[1]) {
        # Update the DockerFile with new ports 0 and 1
        $dockerFilePath = "$($config.billingDatabasePath)\BillingDatabaseFiles\Dockerfile"
        $dockerFile = Get-Content $dockerFilePath
        $updatedDockerFile = $dockerFile | ForEach-Object {
            if ($_ -match 'EXPOSE') {
                return "EXPOSE $($openPorts[0]) $($openPorts[1])"
            } else {
                return $_
            }
        }
        $updatedDockerFile | Set-Content $dockerFilePath
        Write-Output "Port numbers have been successfully updated in $dockerFilePath"
    }

    # Update backend/Dockerfile with new port 1
    if($openPorts[1] -ne $requiredPorts[1]) {
        $backendDockerFilePath = "$($config.billingDatabasePath)\BillingDatabaseFiles\backend\Dockerfile"
        $backendDockerFile = Get-Content $backendDockerFilePath
        $updatedBackendDockerFile = $backendDockerFile | ForEach-Object {
            if ($_ -match 'EXPOSE') {
                return "EXPOSE $($openPorts[1])"
            } else {
                return $_
            }
        }
        $updatedBackendDockerFile | Set-Content $backendDockerFilePath
        Write-Output "Port numbers have been successfully updated in $backendDockerFilePath"
    }

    # Update frontend/Dockerfile with new port 0
    if($openPorts[0] -ne $requiredPorts[0]) {
        $frontendDockerFilePath = "$($config.billingDatabasePath)\BillingDatabaseFiles\frontend\Dockerfile"
        $frontendDockerFile = Get-Content $frontendDockerFilePath
        $updatedFrontendDockerFile = $frontendDockerFile | ForEach-Object {
            if ($_ -match 'EXPOSE') {
                return "EXPOSE $($openPorts[0])"
            } else {
                return $_
            }
        }
        $updatedFrontendDockerFile | Set-Content $frontendDockerFilePath
        Write-Output "Port numbers have been successfully updated in $frontendDockerFilePath"
    }

    # Update frontend/Dockerfile with new port 1
    if($openPorts[1] -ne $requiredPorts[1]) {
        $frontendDockerFilePath = "$($config.billingDatabasePath)\BillingDatabaseFiles\frontend\Dockerfile"
        $frontendDockerFile = Get-Content $frontendDockerFilePath
        $updatedFrontendDockerFile = $frontendDockerFile | ForEach-Object {
            if ($_ -match 'ENV SET_BASE_URL=') {
                return "ENV SET_BASE_URL=""http://localhost:$($openPorts[1])"""
            } else {
                return $_
            }
        }
        $updatedFrontendDockerFile | Set-Content $frontendDockerFilePath
        Write-Output "Port numbers have been successfully updated in $frontendDockerFilePath"
    }
}





# Update paths in automation config
$automationConfigPath = "$($config.billingDatabasePath)\Automations\config.txt"
if (Test-Path $automationConfigPath) {
    $automationConfig = Get-Content $automationConfigPath | ConvertFrom-StringData
    $automationConfig['backupDir'] = "$($config.billingDatabasePath)\Backup"
    $automationConfig['containerName'] = $config.containerName
    $automationConfig['mysqlUser'] = $config.mysqlUser
    $automationConfig['mysqlPassword'] = $config.mysqlPassword
    $automationConfig | Export-CliXml -Path $automationConfigPath
}

# Build Docker container
function Initialize-DockerContainer {
    param (
        [string]$dockerComposePath
    )
    $buildResult = docker-compose -f $dockerComposePath up --build 2>&1
    $errorMessages = $buildResult | Where-Object { $_ -match "error" }
    if ($errorMessages.Count -gt 0) {
        throw "Docker build failed: $($errorMessages -join "`n")"
    }
}

Invoke-Install -path "$($config.billingDatabasePath)\BillingDatabaseFiles\docker-compose.yml" -installFunction {
    Initialize-DockerContainer -dockerComposePath "$($config.billingDatabasePath)\BillingDatabaseFiles\docker-compose.yml"
}

# Run automate_setup.ps1 to finalize the setup
try {
    . "$($config.billingDatabasePath)\Automations\automate_setup.ps1"
    Write-Output "Setup complete."
} catch {
    Write-Error "Automate setup failed: $_"
    exit 1
}
