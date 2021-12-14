# # # # # # # # # # # # # # # # # # # # #
# Automation of spatial data processing #
# using Powershell and PostgreSQL with  #
# PostGIS extension                     #
#                                       #
# Hubert Długosz                        #
# 11.12.2012                            #
# # # # # # # # # # # # # # # # # # # # #

# https://community.spiceworks.com/topic/912118-power-shell-to-unzip-using-7-zip-with-password-protected-zip-file
# https://mailtrap.io/blog/powershell-send-email/

# variables
$workingDirPath = "F:\HUBERT\GEOINFORMATYKA\V semestr\Bazy Danych Przestrzennych\cw8-9"
$downloadsDirPath = "C:\Users\huber\Downloads"
$zipToDownload = "https://home.agh.edu.pl/~wsarlej/Customers_Nov2021.zip"
$dataFileName = "Customers_Nov2021"
$zipPassword = "agh"
$index = "306125"
$TIMESTAMP = Get-Date -Format "ddMMyyyy"

# database related variables
$username = "postgres"
$password = "password"
$hostname = "localhost"
$port = "5432"
$db = "cw8"
$dburl="postgresql://${username}:${password}@${hostname}:${port}/${db}"
$customersTableName = "customers_${index}"
$bestCustomersTableName = "best_customers_${index}"

# SMTP credentials for email notification
$username = "5096121fb3a229"
$password = "ef104308c18029"
$secstr = New-Object -TypeName System.Security.SecureString
$password.ToCharArray() | ForEach-Object {$secstr.AppendChar($_)}
$cred = new-object -typename System.Management.Automation.PSCredential -argumentlist $username, $secstr

# logging function
Function Log {
    param(
        [Parameter(Mandatory=$true)][String]$logString
    )

    $logFilePath = "$workingDirPath\Processed\processing_automation_${TIMESTAMP}.log"

    if (!(Test-Path $logFilePath)) {
        New-Item -path $logFilePath -ItemType File -Force
    }
    else {
        $dateTime = "[{0:dd/MM/yy} {0:HH:mm:ss}]" -f (Get-Date)
        $logMsg = "$dateTime - $logString"
        Add-Content $logFilePath $logMsg
    }
}

# setting current working location
Set-Location -Path $workingDirPath

Log "Running script..."

# cleaning up after earlier execution of the script
Remove-Item -path $downloadsDirPath\$dataFileName*
Remove-Item -path $workingDirPath\$dataFileName*

# downloading data
Start-Process $zipToDownload

Log "Downloading data - Successful"

Start-Sleep -s 1

# configuring 7zip
Set-Alias 7z "$env:ProgramFiles\7-Zip\7z.exe"

# extracting data using 7zip
7z x "${downloadsDirPath}\${dataFileName}.zip" "-p$ZipPassword" "-aoa"


Log "Extracting data - Successful"

# loading data from csv files to variables
$customers = Import-Csv -Path $workingDirPath\$dataFileName.csv

$inputQuantity = $customers.Count # number of input entries

$customersOld = Import-Csv -Path $workingDirPath\Customers_old.csv

# validating data 
$customersNew = @() # new array storing correct entries
$duplicates = 0 # variable storing duplicate entries

for($x = 0 ; $x -lt $customers.Count ; $x++) {
    $exists = 0

    for($y = 0 ; $y -lt $customersOld.Count ; $y++){
        if($customers[$x].email -eq $customersOld[$y].email){
            $exists = 1
            $duplicates = $duplicates + 1
            
            Add-Content $workingDirPath\$dataFileName.bad_${TIMESTAMP}.txt $customersOld[$y]
        }
    }

    if($exists -eq 0) {
        $customersNew = $customersNew + $customers[$x]
    }
}

Log "Validating data - Successful"

# exporting validated data to csv
$customersNew | Export-Csv -Path "$workingDirPath\$dataFileName.csv" -NoTypeInformation
Move-Item -Path "$workingDirPath\$dataFileName.csv" -Destination $workingDirPath\Processed\${TIMESTAMP}_$dataFileName.csv -Force

Log "Moving validated data to subfolder - Successful"

$outputQuantity = $customersNew.Count # number of correct entries

# configuring database 
"CREATE EXTENSION IF NOT EXISTS POSTGIS;" | psql --quiet $dburl

"DROP TABLE IF EXISTS $customersTableName; DROP TABLE IF EXISTS $bestCustomersTableName;" | psql --quiet $dburl

"CREATE TABLE IF NOT EXISTS $customersTableName (first_name VARCHAR(50), last_name VARCHAR(50), email VARCHAR(50), geography GEOGRAPHY(POINT));"  | psql --quiet $dburl

Log "Creating table in db - Successful"

# inserting data into the table
for($x = 0 ; $x -lt $customersNew.Count ; $x++) {
    $first_name = $customersNew[$x].first_name
    $last_name = $customersNew[$x].last_name
    $email = $customersNew[$x].email
    $lat = $customersNew[$x].lat
    $long = $customersNew[$x].long
    $x
    "INSERT INTO $customersTableName VALUES ('${first_name}', '${last_name}', '${email}', 'POINT(${lat} ${long})');" | psql --quiet $dburl
}

Log "Inserting data into the table - Successful"

$tableSize = "SELECT COUNT(*) FROM $customersTableName;"  | psql --quiet $dburl
$tableSize = $tableSize[2] -replace '\s','' #number of inserted entries

# sending notification email
Send-MailMessage -To “script@gmail.com” -From “test@mail.com”  -Subject “CUSTOMERS LOAD - ${TIMESTAMP}” `
                 -Body “Number of lines in the input file: ${inputQuantity}`nNumber of correct lines: ${outputQuantity}`nNumber of duplicates: ${duplicates}`nNumber of entries in the table: ${tableSize}” `
                 -Credential ($cred) -SmtpServer “smtp.mailtrap.io” -Port 587 -ea silentlycontinue

Log "Sending notification email - Successful"

# creating a new table with customers who are within a certain distance from the specified point 
"CREATE TABLE $bestCustomersTableName AS SELECT first_name, last_name, email, geography FROM $customersTableName WHERE `
ST_DistanceSpheroid(geography::geometry, 'SRID=4326; POINT(41.39988501005976 -75.67329768604034)', 'SPHEROID[`"WGS 84`",6378137,298.257223563]')/1000 < 50"   | psql $dburl

Log "Processing data in the db - Successful"

# exporting the above table to csv file
"\copy $bestCustomersTableName to '$bestCustomersTableName.csv' csv header"   | psql --quiet $dburl

Log "Exporting processed data - Successful"

# compressing the above file
7z a $workingDirPath\$bestCustomersTableName.zip $workingDirPath\$bestCustomersTableName.csv 

Log "Creating archive file from processed data - Successful"

$linesQuantity = (Import-Csv $workingDirPath\$bestCustomersTableName.csv  | Measure-Object).Count # number of entries in the csv file

# last modified date of the csv file
$lastModifiedDate = (Get-Item "$workingDirPath\$bestCustomersTableName.csv").LastWriteTime.ToString("dd/MM/yyyy HH:mm") 

# sending notification email with the compressed file as attachment
Send-MailMessage -To “script@gmail.com” -From “test@mail.com”  -Subject “BEST CUSTOMERS RAPORT” `
                 -Body “Number of lines in the csv file: ${linesQuantity}`nLast modified date: $lastModifiedDate” `
                 -Attachments $workingDirPath\$bestCustomersTableName.zip `
                 -Credential ($cred) -SmtpServer “smtp.mailtrap.io” -Port 587 -ea silentlycontinue

Log "Sending notification email with processed data - Successful"