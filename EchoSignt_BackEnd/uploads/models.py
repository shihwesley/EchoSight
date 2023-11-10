from django.db import models


class Image(models.Model):
    image = models.ImageField(upload_to='images/')
    # uploaded_date = models.DateTimeField(auto_now_add=True)
    # uploader = models.CharField(max_length=100)