#Synopsis:
#This script is rertiving data from DNS and clear old records
#Cleanup DNS records requirements for A: 
#- records whose names contain UL or UD and 5 and 6 characters after. For example - PCNEUL00013 or PCDEUD00001
#- records with the same IP. Only the record  with the last registration date (no older than 1 month) is excluded.
#Cleanup DNS records requirements for PTR: 
#-Only the newest record(s) should remain
#Version 1.2

#Function for group objects, because standard function is too slow. This work faster
function Group-ObjectFast
{
    param
    (
        [Parameter(Mandatory,Position=0)]
        [Object]
        $Property,

        [Parameter(ParameterSetName='HashTable')]
        [Alias('AHT')]
        [switch]
        $AsHashTable,

        [Parameter(ValueFromPipeline)]
        [psobject[]]
        $InputObject,

        [switch]
        $NoElement,

        [Parameter(ParameterSetName='HashTable')]
        [switch]
        $AsString,

        [switch]
        $CaseSensitive
    )


    begin 
    {
        # if comparison needs to be case-sensitive, use a 
        # case-sensitive hash table, 
        if ($CaseSensitive)
        {
            $hash = [System.Collections.Hashtable]::new()
        }
        # else, use a default case-insensitive hash table
        else
        {
            $hash = @{}
        }
    }

    process
    {
        foreach ($element in $InputObject)
        {
            # take the key from the property that was requested
            # via -Property

            # if the user submitted a script block, evaluate it
            if ($Property -is [ScriptBlock])
            {
                $key = & $Property
            }
            else
            {
                $key = $element.$Property
            }
            # convert the key into a string if requested
            if ($AsString)
            {
                $key = "$key"
            }
            
            # make sure NULL values turn into empty string keys
            # because NULL keys are illegal
            if ($key -eq $null) { $key = '' }
            
            # if there was already an element with this key previously,
            # add this element to the collection
            if ($hash.ContainsKey($key))
            {
                $null = $hash[$key].Add($element)
            }
            # if this was the first occurrence, add a key to the hash table
            # and store the object inside an arraylist so that objects
            # with the same key can be added later
            else
            {
                $hash[$key] = [System.Collections.ArrayList]@($element)
            }
        }
    }

    end
    {
        # default output are objects with properties
        # Count, Name, Group
        if ($AsHashTable -eq $false)
        {
            foreach ($key in $hash.Keys)
            {
                $content = [Ordered]@{
                    Count = $hash[$key].Count
                    Name = $key
                }
                # include the group only if it was requested
                if ($NoElement -eq $false)
                {
                    $content["Group"] = $hash[$key]
                }
                
                # return the custom object
                [PSCustomObject]$content
            }
        }
        else
        {
            # if a hash table was requested, return the hash table as-is
            $hash
        }
    }
}


$DNSServer = "DC.domain.com" #DNS server

$domainname = "domain.com"

$currentdate = (Get-Date -Format 'yyyy-MM-dd')

$path = ($MyInvocation.MyCommand.Path | Split-Path -Parent)  + "\Reports"   

$resultfile_A = "$path\DNS_Results_of_Delete_A $currentdate.csv"

$resultfile_PTR = "$path\DNS_Results_of_Delete_PTR $currentdate.csv"

If (!(Test-path $path)){New-Item -ItemType Directory -Force -Path $path}


##########################################  CLEANUP A RECORDS  ####################################################################################

# Get new data from DNS
$main_DNS_data = Get-DnsServerResourceRecord -ZoneName $domainname -ComputerName $DNSServer -RRType A | where {$_.Hostname -match "UL\d\d\d\d\d" -or $_.Hostname -match "UD\d\d\d\d\d" -and $_.TimeStamp} | select-object Hostname, @{n="IP";e={$_.RecordData.IPv4Address}},@{n="WhenChanged";e={($_.TimeStamp).ToString("dd.MM.yyyy hh:mm:ss")}}


# Create report base on IP
$List_A = $main_DNS_data | Group-ObjectFast -Property IP  | Where-Object { $_.count -ge 2 } | Foreach-Object { $_.Group } |?{$_.IP -ne ""}

$prev_IP = $List_A[0].IP.IPAddressToString
$SP_name = ""
$SP_LastTimeUpdate = ''

$SP_ALL = @()
$count = 0
Foreach ($object in $List_A)
    {
        $name = ($object.Hostname).split('.')[0]
        $IP = $Object.IP.IPAddressToString

        if ($IP -eq $prev_ip) 
            {
                if (!$SP_name.Contains($name)) {$SP_name += $name +" `n"; $SP_LastTimeUpdate += $object.WhenChanged +" `n";  $count++}
            }
        else 
            {   
                if (($count -gt 1) -and ($prev_ip.split('.')[0]  -eq '10'))
                    {
                        $SP_item = @{}
                        $SP_item.Hostnames = $SP_name.Substring(0,$SP_name.Length - 1)
                        $SP_item.IP = $prev_ip
                        $SP_item.DNS_TimeStamp = $SP_LastTimeUpdate.Substring(0,$SP_LastTimeUpdate.Length - 1)

                        $Objectname = New-Object PSobject -Property $SP_item

                        $SP_All += $Objectname
                    }
                $SP_name = $name + " `n"
                $prev_ip = $IP  
                $SP_LastTimeUpdate =$object.WhenChanged + " `n" 
                $count = 0  
            }

    }

############## Clear old DNS A records   ##################################

#Prepare report with records to be deleted
$records = [System.Collections.ArrayList]::new(); # List of records that should be deleting

$count_for_phase = 0

Foreach ($item in $SP_All)
    {
        $IP = $item.IP # Get IP for A records
        $Hostnames = $item.Hostnames -split "`n" # get
        $DNS_TimeStamp = $item.DNS_TimeStamp -split "`n"

        $lastdate = $DNS_TimeStamp | %{([datetime]::ParseExact(($_).Trim(),"dd.MM.yyyy HH:mm:ss",$Null)).Date } | Sort | select -Last 1
             
        For ($i = 0; $i -le $n + 1; $i++)
            {
                $checkdate = ([datetime]::ParseExact(($DNS_TimeStamp[$i]).Trim(),"dd.MM.yyyy HH:mm:ss",$Null)).Date
      
                if ($checkdate -ne $lastdate -or $lastdate -lt (get-date).AddMonths(-1)) 
                    {
                        $DeleteRec = "True"
                        $count_for_phase++
                    }
                else
                    {
                            try 
                            {
                                $server = $Hostnames[$i] 
                                $temp = Get-ADComputer $server.Trim() -ErrorAction Stop
                                $DeleteRec = "False"
                            }
                        catch
                            {
                                $DeleteRec = "True"
                                $count_for_phase++
                            }
                    }

                    $NewObject = @( 
                        [pscustomobject]@{
                            "IP" = "$IP"
                            "Hostname" = "$($Hostnames[$i])"
                            "Date" = "$($DNS_TimeStamp[$i])"
                            "Delete" = $DeleteRec
                        }
                        )
                $records += $NewObject   #Append record in massive
                                
            }
    }

#Start to delete old records

Foreach ($item in $records)
{
    $Status = "Skip"
    if ($item.Delete -eq "True")
        {

            $rec_IP = $item.IP
            $rec_name = $item.Hostname

            try
                {
                    Remove-DnsServerResourceRecord -ZoneName $domainname -ComputerName $DNSServer -RecordData $rec_IP.Trim() -Name $rec_name.Trim() -RRType "A" -Force -ErrorAction Stop
                    $Status = "Delete"
                }
            catch
                {
                    $Status = "Fail"    
                }
        }
    $newitem = $item
    $newitem| Add-Member -MemberType NoteProperty -Name 'Status' -Value $Status
    $newitem | Export-csv $resultfile_A -NoTypeInformation -Delimiter ';' -Encoding UTF8 -Append
}
 
      
##########################################  CLEANUP PTR RECORDS  ####################################################################################

### Get ALL PTR records from ALL zone of domain ###
$reversezones = Get-DnsServerZone -ComputerName $DNSServer| Select ZoneName, IsReverseLookupZone | Where {$_.IsReverseLookupZone -eq "True"} # get zones

$result_items = $null

Foreach ($zone in $reversezones)
    {
        $zone_IP = (($zone.ZoneName -split "in")[0]) 
        $zone_IP_arr  = ($zone_IP.substring(0,$zone_IP.length -1)).Split('.')
        $IP_scope = ''
        Foreach ($item in $zone_IP_arr) {$IP_scope = $item +'.' +$IP_scope}

        $records = Get-DnsServerResourceRecord -ZoneName $zone.ZoneName -ComputerName $DNSServer  -RRType PTR  | ?{ $_.Timestamp -ne $null} #exclude static records by using  $_.Timestamp -ne $null
        if ($records.count -gt 1)
            {
                foreach ($record in $records)
                    {
                        if ($record.Hostname.Contains('.'))
                            {
                                $temp_arr  = $record.Hostname.Split('.')
                                $IP_hostname  = ''
                                Foreach ($item in $temp_arr) {$IP_hostname  = $item +'.' + $IP_hostname}
                                $IP_hostname = $IP_hostname.Substring(0,$IP_hostname.Length - 1)
                            }
                        else {$IP_hostname = $record.Hostname}

                        $result_items += @( 
                        [pscustomobject]@{
                                IP = $($IP_scope + $IP_hostname)
                                IP_PTR = $record.Hostname
                                Name = $record.RecordData.PtrDomainName
                                Timestamp = $record.Timestamp
                                IP_scope = $IP_scope
                                Name_Zone = $zone.ZoneName
                            }
                        )
                    }
            }
    }


### Preapire list for cleanup ###
$result_items2 = $result_items | Sort-Object -Property Name |  Group-ObjectFast -Property Name | ?{$_.count -gt 1} # get only records with same IP but different names

$record  = $null
$result_action_ptr = @()
$result_action_a = @()

Foreach ($item in $result_items2)
    {
        $records = $item.Group | Sort-Object -Property Timestamp -Descending
        $hostname = (($records[0].Name).Split('.'))[0] # Get a record name  with the latest date
        $IP_PTR = $records[0].IP                       # Get a record IP  with the latest date
        $Timestamp_PTR = $records[0].Timestamp         
        try
            {
                #Check if A record exists for PTR name
                $A_records = Get-DnsServerResourceRecord -ZoneName $domainname -ComputerName $DNSServer -RRType A -Name $hostname -ErrorAction Stop | select-object Hostname, @{n="IP";e={$_.RecordData.IPv4Address}},@{n="WhenChanged";e={($_.TimeStamp).ToString("dd.MM.yyyy hh:mm:ss")}} | Sort-Object -Property WhenChanged -Descending
            }
        catch
            {
                $A_records = $null
            }     
        if ($A_records)       
            { 
                $IP_A = $A_Records[0].IP.IPAddressToString
                $IP_A_array = $A_Records | select IP,WhenChanged
                $Timestamp_A =$A_Records[0].WhenChanged
                try
                    {
                        $Timestamp_A = [datetime]::ParseExact($A_Records[0].WhenChanged,'dd.MM.yyyy HH:mm:ss',$null).GetDateTimeFormats()[71]
                    }
                catch
                    {

                    }
                Foreach ($record in $records)
                    {
                        if ($record.IP -notin  $IP_A_array.IP) {$record | Add-Member -MemberType NoteProperty -Name "Action" -Value "Delete"} #skip only PRT record with IP == IP A record
                        else {$record | Add-Member -MemberType NoteProperty -Name "Action" -Value "Skip"} 
                        try
                            {    
                                if ($IP_A_array.WhenChanged) {$record | Add-Member -MemberType NoteProperty -Name "Timestamp_A_record" -Value ($IP_A_array.WhenChanged -join " ")}
                                else {$record | Add-Member -MemberType NoteProperty -Name "Timestamp_A_record" -Value ""}
                            }
                        catch
                            {
                            }
                        try
                            {
                                $record | Add-Member -MemberType NoteProperty -Name "IP_A_record" -Value ($IP_A_array.IP.IpAddressToString -join " ")
                            }
                        catch
                            {
                            }
                        $result_action_ptr += $record      
                    }  
            }
        else
            {
                 Foreach ($record in $records)
                    {
                       $record | Add-Member -MemberType NoteProperty -Name "Action" -Value "No_A_record"
                    }

            }
    }


 ### Delete PTR records ###
 Foreach ($record in $result_action_ptr)
    {
        $Status = "Skip"
        if ($record.Action -eq "Delete")
            {
                $IPAddress = $record
                $IPAddressFormatted = $record.IP_PTR
                $ReverseZoneName = $record.Name_zone

                $NodePTRRecord = Get-DnsServerResourceRecord -ZoneName $ReverseZoneName -ComputerName $DNSServer -Node $IPAddressFormatted -RRType Ptr -ErrorAction SilentlyContinue
                if($NodePTRRecord -eq $null)
                    {
                        $Status = "Skip"
                    } 
                else 
                    {
                        try
                            {
                                Remove-DnsServerResourceRecord -ZoneName $ReverseZoneName -ComputerName $DNSServer -InputObject $NodePTRRecord -Force -WhatIf:$bTest
                                $Status = "Delete"
                            }
                        catch
                            {
                                $Status = "Fail" 
                            }
                    }

            }
           
            $newitem = $record
            $newitem | Add-Member -MemberType NoteProperty -Name 'Status' -Value $Status
            $newitem | Export-csv $resultfile_PTR -NoTypeInformation -Delimiter ';' -Encoding UTF8 -Append 
    } 