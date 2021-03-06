﻿function writeToJSON {
param
    ($Map) 
    $list = @()

    $Map.GetEnumerator() | % {
        $list += $_.Value
    }
    ConvertTo-Json $list | Out-File -FilePath "info.json" -Force
}

function sendToElk {
    param($element)

    Invoke-WebRequest -Uri "ELK URI" -Body $(ConvertTo-JSON $element) -Method POST -ContentType "application/json" | Out-NUll
}

$Hostnames = Get-Content "hostnames.txt"

$hosts = @{}

$Hostnames | foreach {
    Write-Host("$_")
    $cred = Get-Credential -Message "Getting credentials for $_" -UserName "$_\"
    $hosts.add($_, $cred)
} 

  
  $codeBlock = {
    param($creds, $hostname)
    Invoke-Command -ComputerName $hostname -Credential $creds -ScriptBlock {
        $a = Get-Counter
        $value = New-Object System.Object
        $value | Add-Member -type NoteProperty -Name Name -Value $(hostname)
        $netValue = 0;
        $a.CounterSamples | foreach {
           if ($_.Path.Contains("network")) {
            $netValue += $_.CookedValue
           }
           elseif ($_.Path.Contains("processor")) {
            $value | Add-Member -type NoteProperty -Name CPU -Value $([math]::Round($_.CookedValue,2))    
           } 
           elseif ($_.Path.Contains("memory\%")) {
            $value | Add-Member -type NoteProperty -Name Memory -Value $([math]::Round($_.CookedValue,2))         
           }
           elseif ($_.Path.Contains("disk time")) {
            $value | Add-Member -type NoteProperty -Name Disk -Value $([math]::Round($_.CookedValue,2))         
           }
        }

        $value | Add-Member -type NoteProperty -Name Timestamp -Value $(Get-Date $a.Timestamp -Format yyyy\-MM\-dd\THH\:mm\:sszzz)
        $value | Add-Member -type NoteProperty -Name Network -Value $([math]::Round($netValue,2))    
        $value
    }
}

$jobs = @{}

$hosts.GetEnumerator() | % {
    $job = Start-Job $codeBlock -ArgumentList $_.Value, $_.Key
    $jobs.add($job.Id, $_.Key)
}

#$job = Start-Job $codeBlock -ArgumentList $creds, "Tec-7040-itb-01"
#$job = Start-Job $codeBlock -ArgumentList $creds, ""



$values = @{}

#Job deletion get's weird if we don't let it get it's bearings. 
Start-Sleep -Milliseconds 5000

#run until we tell it to stop
while($true) {
    $q = Get-Job -State Completed 
    $c = $q | Receive-Job
    if ($c) {
        $c | foreach {
            if ($values.ContainsKey($_.Name)) {
                $values[$_.Name] = $_
            } else {
                $values.Add($_.Name, $_)
            }
            sendToElk($_)
            writeToJSON -Map $values
        }
    }

    #Restart jobs for all completed machines. This way even if one errors out it'll come back when it the machine restarts (or becomes available again) 
    $q | foreach {
        Remove-Job -job $_
        $name = $jobs[$_.Id]
        $job = Start-Job $codeBlock -ArgumentList $hosts[$name], $name
        $jobs.Remove($_.Id)
        $jobs.Add($job.Id, $name)
    }

    #Run a look through our jobs to see if any have been running for a long time ( > 1min) if so, restart it. 
    Get-Job | foreach {
        $span = New-Timespan -Start $_.PSBeginTime -End $(Get-Date)
        if ($span.TotalSeconds -gt 60) {
            $name = $jobs[$_.Id]
            write-Host("Restarting job:" + $_.Id + ": " + $name)

            Remove-Job -job $_ -Force
            $job = Start-Job $codeBlock -ArgumentList $hosts[$name], $name
            $jobs.Remove($_.Id)
            $jobs.Add($job.Id, $name)
        }
    }

    Start-Sleep -Milliseconds 500
}