# Example url patterns in your_app/urls.py
from django.urls import path

from .views import ImageUploadView

urlpatterns = [
    path('image/', ImageUploadView.as_view(), name='image_upload'),
]
