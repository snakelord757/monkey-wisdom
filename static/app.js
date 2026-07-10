(() => {
  "use strict";

  const levels = [
    "Глупый бибизян",
    "Банан потерял",
    "Ищет кожуру",
    "Юный мартыш",
    "Банановый ученик",
    "Смышлёный примат",
    "Опытный горилла",
    "Хранитель стаи",
    "Седой вожак",
    "Великий Сильвербек",
    "Жесть мудрый бибизян"
  ];

  const form = document.querySelector("#wisdom-form");
  const question = document.querySelector("#question");
  const slider = document.querySelector("#wisdom-level");
  const levelName = document.querySelector("#level-name");
  const temperatureValue = document.querySelector("#temperature-value");
  const characterCount = document.querySelector("#character-count");
  const validation = document.querySelector("#validation-message");
  const answerPanel = document.querySelector("#answer-panel");
  const answerKicker = document.querySelector("#answer-kicker");
  const answerText = document.querySelector("#answer-text");
  const submitButton = document.querySelector("#submit-button");
  const submitLabel = submitButton.querySelector(".button-label");
  const retryButton = document.querySelector("#retry-button");
  let submitting = false;

  function updateLevel() {
    const wisdomLevel = Number(slider.value);
    const index = Math.round(wisdomLevel * 10);
    const temperature = (1 - wisdomLevel).toFixed(1);
    levelName.textContent = levels[index];
    temperatureValue.textContent = temperature;
    slider.setAttribute("aria-valuetext", `${levels[index]}, температура ${temperature}`);
    slider.style.setProperty("--range-progress", `${wisdomLevel * 100}%`);
  }

  function updateCount() {
    characterCount.textContent = `${question.value.length} / ${question.maxLength}`;
    if (question.value.trim()) {
      validation.textContent = "";
      question.classList.remove("is-invalid");
      question.removeAttribute("aria-invalid");
    }
  }

  function showState(state, kicker, message) {
    answerPanel.className = `answer-panel is-${state}`;
    answerKicker.textContent = kicker;
    answerText.textContent = message;
    retryButton.hidden = state !== "error";
  }

  function setSubmitting(value) {
    submitting = value;
    submitButton.disabled = value;
    slider.disabled = value;
    submitLabel.textContent = value ? "Сильвербек размышляет…" : "Получить мудрость";
  }

  async function submitQuestion(event) {
    event?.preventDefault();
    if (submitting) return;

    const text = question.value.trim();
    if (!text) {
      validation.textContent = "Сначала задай вопрос.";
      question.classList.add("is-invalid");
      question.setAttribute("aria-invalid", "true");
      question.focus();
      return;
    }

    validation.textContent = "";
    question.classList.remove("is-invalid");
    setSubmitting(true);
    showState("loading", "Слышен шелест листьев", "Сильвербек размышляет над банановой рощей…");

    try {
      const response = await fetch("/api/wisdom", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ question: text, wisdomLevel: Number(slider.value) })
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.detail || "Не удалось получить мудрость. Попробуй ещё раз.");
      if (!data.wisdom || !data.wisdom.trim()) throw new Error("Сильвербек промолчал. Попробуй спросить иначе.");
      showState("success", "Слово Сильвербека", data.wisdom.trim());
    } catch (error) {
      const message = error instanceof Error ? error.message : "Не удалось получить мудрость. Попробуй ещё раз.";
      showState("error", "Тропа оборвалась", message);
    } finally {
      setSubmitting(false);
    }
  }

  slider.addEventListener("input", updateLevel);
  question.addEventListener("input", updateCount);
  question.addEventListener("keydown", (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key === "Enter") submitQuestion(event);
  });
  form.addEventListener("submit", submitQuestion);
  retryButton.addEventListener("click", submitQuestion);

  updateLevel();
  updateCount();
})();
