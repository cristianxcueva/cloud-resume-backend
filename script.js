document.addEventListener("DOMContentLoaded", function() {
    // Fetch the visitor count from the server
    fetch("https://0pvaktzl0m.execute-api.us-east-1.amazonaws.com/visitor-count")
        .then(response => response.json())
        .then(data => {
           document.getElementById("visitor-count").textContent = "Visitor Count: " + data.count;
        })
        .catch(error => {
            console.error("Error fetching visitor count:", error);
        }); 
});
