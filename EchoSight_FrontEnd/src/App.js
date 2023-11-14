// Ensure the DOM is fully loaded
document.addEventListener('DOMContentLoaded', function() {

    // Attach an event listener to the upload button
    document.getElementById('upload-btn').addEventListener('click', function() {
        // Retrieve the file input element and the file itself
        var photoInput = document.getElementById('photo-input');
        var file = photoInput.files[0]; // Assuming single file upload

        // Check if a file is selected
        if (file) {
            // Instantiate FormData to send the file as a multi-part form data
            var formData = new FormData();
            formData.append('photo', file);

            // Use the fetch API to send an asynchronous request to your server
            fetch('https://api.echo-sight.com:8000/api/upload/image/', {
                method: 'POST',
                body: formData
            })
            .then(response => {
                // Check if the request was successful
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }
                return response.json(); // Parse JSON response
            })
            .then(data => {
                console.log('Success:', data);
                alert('Photo uploaded successfully!');

                // Decode the base64 audio and create a blob
                const audioBlob = new Blob([Uint8Array.from(atob(data.audio), c => c.charCodeAt(0))], {type: 'audio/mpeg'});
                const audioUrl = URL.createObjectURL(audioBlob);

                // Create an audio element
                var audioPlayer = document.createElement('audio');
                audioPlayer.src = audioUrl;
                audioPlayer.controls = true;
                audioPlayer.autoplay = true;

                // Append the audio player to the body or a specific element
                document.body.appendChild(audioPlayer);
            })
            .catch((error) => {
                // Handle any errors that occurred during the fetch
                console.error('Error during fetch:', error);
                alert('Error uploading photo.');
            });
        } else {
            // No file was selected
            alert('Please select a photo to upload.');
        }
    });

});
