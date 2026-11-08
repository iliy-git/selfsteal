document.addEventListener('DOMContentLoaded', () => {
    const yearEl = document.getElementById('currentYear');
    if (yearEl) {
        yearEl.textContent = new Date().getFullYear();
    }

    const navToggle = document.getElementById('navToggle');
    const navMenu = document.getElementById('navMenu');
    if (navToggle && navMenu) {
        navToggle.addEventListener('click', () => {
            navMenu.classList.toggle('active');
        });

        navMenu.querySelectorAll('.nav-link').forEach(link => {
            link.addEventListener('click', () => {
                navMenu.classList.remove('active');
            });
        });
    }

    const contactForm = document.getElementById('contactForm');
    const formFeedback = document.getElementById('formFeedback');
    if (contactForm && formFeedback) {
        contactForm.addEventListener('submit', (e) => {
            e.preventDefault();
            formFeedback.style.color = '#10b981';
            formFeedback.textContent = '✓ Спасибо! Ваше сообщение принято.';
            contactForm.reset();
            setTimeout(() => {
                formFeedback.textContent = '';
            }, 5000);
        });
    }
});
