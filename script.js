document.addEventListener("DOMContentLoaded", function() {
    // Fetch the visitor count from the server
    fetch("PLACEHOLDER_API_URL")
        .then(response => response.json())
        .then(data => {
           document.getElementById("visitor-count").textContent = "Visitor Count: " + data.count;
        })
        .catch(error => {
            console.error("Error fetching visitor count:", error);
        }); 
});
