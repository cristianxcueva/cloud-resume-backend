# Cloud Resume Challenge: Frontend

The actual resume site. Plain HTML, CSS, and JavaScript, deployed to S3 behind CloudFront.

Live site: [cristianxcueva.dev](https://cristianxcueva.dev)

Backend repo (Terraform, Lambda, the visitor counter API): [cloud-resume-backend](https://github.com/cristianxcueva/cloud-resume-backend)

---

## What's Here

- `index.html` / `style.css`: the resume itself
- `script.js`: calls the visitor counter API and writes the result into the page
- `error.html`: served by S3 for any missing path

No build step, no framework, no Terraform. This repo's job is the static files and getting them onto S3 when they change.

---

## How It Connects to the Backend

The S3 bucket and CloudFront distribution this repo deploys into don't live here, they're provisioned by the backend repo's Terraform. This repo only ever uploads into infrastructure that already exists.

`script.js` calls the backend's API Gateway endpoint directly from the browser, that's a separate request from the page load itself, not something this repo's pipeline touches.

---

## CI/CD

On every push to `main`: checkout, sync the files to S3, invalidate the CloudFront cache so the new version is live immediately instead of waiting for the old cache to expire.

Authenticates through a dedicated IAM user, scoped to exactly two things: writing to this one S3 bucket, and invalidating this one CloudFront distribution. No DynamoDB access, no Lambda access, no IAM access, none of it is needed here.

---

## Project History

This repo split off from a single combined repository once CI/CD needed two separate pipelines. The original, unsplit commit history from Milestones 1 through 6 lives on the `build-history` branch here and in the backend repo.

---

## Author

Cristian Cueva, IT Support Analyst transitioning into Cloud Engineering
[GitHub](https://github.com/cristianxcueva)
