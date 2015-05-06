﻿Set-StrictMode -Version Latest

function Get-ZLocationBackupFilePath
{
    return (Join-Path $env:HOMEDRIVE (Join-Path $env:HOMEPATH 'z-location.txt'))
}

function Get-ZLocationPipename
{
    return 'zlocation'
}

#
# Return ready-to-use ZLocation.IService proxy.
# Starts service server side, if nessesary
#
function Get-ZService()
{
    $baseAddress = "net.pipe://localhost"

    function log([string] $message)
    {
        # You can replace logs for development, i.e:
        # Write-Host -ForegroundColor Yellow "[ZLocation] $message"
        Write-Verbose "[ZLocation] $message"
    }

    #
    # Add nessesary types.
    #
    function Set-Types()
    {
        log "Enter Set-Types"
        if ("ZLocation.IService" -as [type])
        {
            log "[ZLocation] Types already added"
            return
        }
        $smaTime = Measure-Command { Add-Type -AssemblyName System.ServiceModel }
        log "Add System.ServiceModel assembly in $($smaTime.TotalSeconds) sec"
        $csCode = cat (Join-Path $PSScriptRoot "service.cs") -Raw
        $serviceTime = Measure-Command { Add-Type -ReferencedAssemblies System.ServiceModel -TypeDefinition $csCode }
        log "Compile and add ZLocation storage service in $($serviceTime.TotalSeconds) sec"
    }

    #
    # Called only if Types are already populated
    #
    function Get-Binding()
    {
        if (-not (Test-Path variable:Script:binding)) {
            log "Create new .NET pipe service binding"
            $Script:binding = [System.ServiceModel.NetNamedPipeBinding]::new()
            $Script:binding.OpenTimeout = [timespan]::MaxValue
            $Script:binding.CloseTimeout = [timespan]::MaxValue
            $Script:binding.ReceiveTimeout = [timespan]::MaxValue
            $Script:binding.SendTimeout = [timespan]::MaxValue
        }
        return $Script:binding
    }

    #
    # Return cached proxy, or create a new one, if -Force
    #
    function Get-ZServiceProxy([switch]$Force)
    {
        if ((-not (Test-Path variable:Script:pipeProxy)) -or $Force) 
        {
            Set-Types
            $pipeFactory = [System.ServiceModel.ChannelFactory[ZLocation.IService]]::new(
                (Get-Binding), 
                [System.ServiceModel.EndpointAddress]::new( $baseAddress + '/' + (Get-ZLocationPipename) )
            )    
            $Script:pipeProxy = $pipeFactory.CreateChannel()
        }
        $Script:pipeProxy
    }

    #
    # 
    #
    function Start-ZService()
    {
        Set-Types
        $service = [System.ServiceModel.ServiceHost]::new([ZLocation.Service]::new( (Get-ZLocationBackupFilePath) ), [uri]($baseAddress))

        # It will be usefull to add debugBehaviour, like this
        # $debugBehaviour = $service.Description.Behaviors.Find[System.ServiceModel.Description.ServiceDebugBehavior]();
        # $debugBehaviour = [System.ServiceModel.Description.ServiceDebugBehavior]::new()
        # $debugBehaviour.IncludeExceptionDetailInFaults = $true
        # $service.Description.Behaviors.Add($debugBehaviour);

        $service.AddServiceEndpoint([ZLocation.IService], (Get-Binding), (Get-ZLocationPipename) ) > $null
        $service.Open() > $null
    }

    $service = Get-ZServiceProxy
    $retryCount = 0
    while ($true) 
    {
        $retryCount++
        try {
            $service.Noop()
            break;
        } catch {
            if ($retryCount -gt 1)
            {
                Write-Error "Cannot connect to a storage service. $_"
                break;
            }
            Start-ZService
            $service = Get-ZServiceProxy -Force
        }
    }

    $service
}

function Get-ZLocation()
{
    $service = Get-ZService
    $hash = @{}
    foreach ($item in $service.Get()) 
    {
        $hash.add($item.Key, $item.Value)
    }    
    return $hash
}

function Add-ZWeight([string]$path, [double]$weight) {
    $service = Get-ZService
    $service.Add($path, $weight)
}

function Remove-ZLocation([string]$path) {
    $service = Get-ZService
    $service.Remove($path)
}

$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
    Write-Warning "[ZLocation] module was removed, but service was not closed."
}

Export-ModuleMember -Function @("Get-ZLocation", "Add-ZWeight", "Remove-ZLocation")
