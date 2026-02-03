# coding=utf-8
"""
Local Django settings for Regluit development with Docker.

This file is designed to work with the Docker Compose setup in
regluit-provisioning/docker/docker-compose.yml.

Usage:
    1. Copy this file to your regluit checkout:
       cp regluit-provisioning/regluit/settings/local.py regluit/settings/

    2. Start Docker services:
       cd regluit-provisioning/docker && docker-compose up -d

    3. Run Django with these settings:
       DJANGO_SETTINGS_MODULE=regluit.settings.local python manage.py runserver

Environment variables (optional overrides):
    MYSQL_HOST, MYSQL_PORT, MYSQL_DATABASE, MYSQL_USER, MYSQL_PASSWORD
    REDIS_HOST, REDIS_PORT
    EMAIL_HOST, EMAIL_PORT
"""

import os
from .common import *

# Debug mode for development
DEBUG = True
TEMPLATES[0]['OPTIONS']['debug'] = DEBUG

# Allow all hosts in development
ALLOWED_HOSTS = ['*']

# Local site settings
IS_PREVIEW = True
SITE_ID = 1

# Admins for error emails
ADMINS = [
    ('Local Developer', 'developer@localhost'),
]
MANAGERS = ADMINS

# Database - Docker MySQL
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': os.environ.get('MYSQL_DATABASE', 'regluit'),
        'USER': os.environ.get('MYSQL_USER', 'regluit'),
        'PASSWORD': os.environ.get('MYSQL_PASSWORD', 'regluit_pass'),
        'HOST': os.environ.get('MYSQL_HOST', '127.0.0.1'),
        'PORT': os.environ.get('MYSQL_PORT', '3306'),
        'OPTIONS': {
            'charset': 'utf8mb4',
            'init_command': "SET sql_mode='STRICT_TRANS_TABLES'",
        },
        'TEST': {
            'CHARSET': 'utf8mb4',
            'COLLATION': 'utf8mb4_unicode_ci',
        }
    }
}

# Time zone
TIME_ZONE = 'America/New_York'

# Email - Use MailHog in Docker for testing
EMAIL_BACKEND = 'django.core.mail.backends.smtp.EmailBackend'
EMAIL_HOST = os.environ.get('EMAIL_HOST', '127.0.0.1')
EMAIL_PORT = int(os.environ.get('EMAIL_PORT', '1025'))
EMAIL_USE_TLS = False
DEFAULT_FROM_EMAIL = 'dev@localhost'

# Celery - Docker Redis
CELERY_BROKER_URL = 'redis://{}:{}/0'.format(
    os.environ.get('REDIS_HOST', '127.0.0.1'),
    os.environ.get('REDIS_PORT', '6379')
)
CELERY_RESULT_BACKEND = CELERY_BROKER_URL

# Don't hijack root logger in development
WORKER_HIJACK_ROOT_LOGGER = False

# Base URL for local development
BASE_URL_SECURE = 'http://localhost:8000'

# Simplified logging for development
LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'formatters': {
        'verbose': {
            'format': '{levelname} {asctime} {module} {process:d} {thread:d} {message}',
            'style': '{',
        },
        'simple': {
            'format': '{levelname} {message}',
            'style': '{',
        },
    },
    'handlers': {
        'console': {
            'level': 'DEBUG',
            'class': 'logging.StreamHandler',
            'formatter': 'simple',
        },
    },
    'root': {
        'handlers': ['console'],
        'level': 'INFO',
    },
    'loggers': {
        'django': {
            'handlers': ['console'],
            'level': 'INFO',
            'propagate': False,
        },
        'django.db.backends': {
            'handlers': ['console'],
            'level': 'WARNING',  # Set to DEBUG to see SQL queries
            'propagate': False,
        },
        'regluit': {
            'handlers': ['console'],
            'level': 'DEBUG',
            'propagate': False,
        },
    },
}

# Static files - serve locally
STATIC_ROOT = os.path.join(BASE_DIR, 'static_collected')
STATIC_URL = '/static/'

# Media files - local storage instead of S3
DEFAULT_FILE_STORAGE = 'django.core.files.storage.FileSystemStorage'
MEDIA_ROOT = os.path.join(BASE_DIR, 'media')
MEDIA_URL = '/media/'

# Celery beat schedule - minimal for development
CELERYBEAT_SCHEDULE = {}

# Disable Google Analytics in development
SHOW_GOOGLE_ANALYTICS = False

# Sandbox Amazon FPS for testing
AMAZON_FPS_HOST = "fps.sandbox.amazonaws.com"

# Maintenance mode off
MAINTENANCE_MODE = False

# Accept all content types for Celery
ACCEPT_CONTENT = ['pickle', 'json', 'msgpack', 'yaml']

# Development-specific settings
# Uncomment these as needed for testing specific features

# Use console email backend (prints to terminal)
# EMAIL_BACKEND = 'django.core.mail.backends.console.EmailBackend'

# Use file email backend (writes to /tmp/emails/)
# EMAIL_BACKEND = 'django.core.mail.backends.filebased.EmailBackend'
# EMAIL_FILE_PATH = '/tmp/emails/'

# Enable Django Debug Toolbar (if installed)
# INSTALLED_APPS += ['debug_toolbar']
# MIDDLEWARE += ['debug_toolbar.middleware.DebugToolbarMiddleware']
# INTERNAL_IPS = ['127.0.0.1']

# Stripe test keys (replace with your test keys)
# STRIPE_PK = 'pk_test_...'
# STRIPE_SK = 'sk_test_...'
