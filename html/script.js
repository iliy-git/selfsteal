document.addEventListener('DOMContentLoaded', () => {
    // Current year
    const yearEl = document.getElementById('year');
    if (yearEl) {
        yearEl.textContent = new Date().getFullYear();
    }

    // Mobile nav toggle
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

    // Product buy button feedback
    document.querySelectorAll('.buy-btn').forEach(btn => {
        btn.addEventListener('click', (e) => {
            const product = e.target.getAttribute('data-product');
            const originalText = e.target.textContent;
            e.target.textContent = '✓ В корзине';
            e.target.style.backgroundColor = '#10b981';
            e.target.style.color = '#fff';
            setTimeout(() => {
                e.target.textContent = originalText;
                e.target.style.backgroundColor = '';
                e.target.style.color = '';
            }, 2000);
        });
    });

    // Lead Form submission feedback
    const leadForm = document.getElementById('leadForm');
    const formResult = document.getElementById('formResult');
    if (leadForm && formResult) {
        leadForm.addEventListener('submit', (e) => {
            e.preventDefault();
            formResult.style.color = '#059669';
            formResult.textContent = '✓ Заявка принята! Менеджер свяжется с вами в течение 10 минут.';
            leadForm.reset();
            setTimeout(() => {
                formResult.textContent = '';
            }, 6000);
        });
    }
});
