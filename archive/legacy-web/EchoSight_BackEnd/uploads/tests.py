from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase
from rest_framework.test import APIClient


class ImageUploadViewTest(TestCase):
    def test_image_upload(self):
    # Create an in-memory image file for testing
        image_file = SimpleUploadedFile(
            name='test_image.jpg',
            content=open('/Users/the.shih/Django/my_django_project/uploads/Screen Shot 2023-10-17 at 9.46.30 PM.png', 'rb').read(),
            content_type='image/jpeg'
        )

        # Create the data to send in the request
        data = {'image': image_file}

        # Make a POST request to the view
        response = self.client.post('/api/upload/image/', data)

        # Check that the response status code is 201 (Created)
        self.assertEqual(response.status_code, 201)


# Unused imports removed
