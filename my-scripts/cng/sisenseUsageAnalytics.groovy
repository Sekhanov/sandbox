@Grab(group='org.apache.commons', module='commons-csv', version='1.9.0')
import org.apache.commons.csv.CSVFormat
import org.apache.commons.csv.CSVRecord
import java.nio.file.Files
import java.nio.file.Paths

// Path to your CSV file
def filePath = '/Users/sekhanov/Downloads/ba-5459/sand-prod/sand/reporting77schkc8md2p2i5/date=2024-07-01/2024.07.01-03.08.14.11294245_usage_analytics.csv'

// Reading the CSV file
def reader = Files.newBufferedReader(Paths.get(filePath))
def records = CSVFormat.DEFAULT.withFirstRecordAsHeader().parse(reader)

records.each { CSVRecord record ->
    // Access fields using header names
    println "Name: ${record.get('Name')}, Age: ${record.get('Age')}, Country: ${record.get('Country')}"
}

reader.close()