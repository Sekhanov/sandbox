// Variables and Data Types
def name = 'John'        // Dynamic typing
String city = 'NYC'      // Explicit typing
int age = 30             // Integer
double price = 19.99     // Double
boolean isActive = true  // Boolean

//list
println "list"
def list = [1, 2, 3, 4]
list << 5                // Append element
println list[0]          // Access element
list[1] = 10             // Modify element
list.each { print it + ", "} // Iterate over elements

// map
println "map"
def map = [name: 'John', age: 30]
map.city = 'NYC'        // Add element
println map['name']     // Access element
map.each { k, v -> println "$k: $v" } // Iterate over elements
map.each { println it } // Iterate over elements
map.each { println it.key + it.value } // Iterate over elements

// iterate
for (i in 1..10) print i
println ""

//spread operator *
println "spread"
def list1 = [1, 2, 3]
println list1*.toString()  // ["1", "2", "3"]

// safe navigation
def person = null
println person?.name  // Avoids NullPointerException

// Elvis Operator
def name1 = null
def displayName = name1 ?: 'Unknown'
println displayName


// method
def getGreet(String name) {
    return "hello, $name";
}
println getGreet("Ivan")

// closure

//------------------------------------

// File IO

// Writing to a file
new File('example.txt').withWriter('UTF-8') { writer ->
    writer.writeLine 'Hello, Groovy!'
}
// Reading a file
new File('example.txt').eachLine { line ->
    println line
}


// json
import groovy.json.JsonOutput
import groovy.json.JsonSlurper

println "json"
def jsonString = '{"name":"John", "age":30}'
def json = new JsonSlurper().parseText(jsonString)
println json.name  // Johna

def outputJson = JsonOutput.toJson([name: 'John', age: 30])
println outputJson  // {"name":"John","age":30}


//http
// GET
def get = new URL("https://httpbin.org/get").openConnection();
def getRC = get.getResponseCode();
println(getRC);
if (getRC.equals(200)) {
    println(get.getInputStream().getText());
}

// POST
def post = new URL("https://httpbin.org/post").openConnection();
def message = '{"message":"this is a message"}'
post.setRequestMethod("POST")
post.setDoOutput(true)
post.setRequestProperty("Content-Type", "application/json")
post.getOutputStream().write(message.getBytes("UTF-8"));
def postRC = post.getResponseCode();
println(postRC);
if (postRC.equals(200)) {
    println(post.getInputStream().getText());
}
