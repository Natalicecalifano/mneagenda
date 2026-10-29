<!-- LOVABLE:BEGIN -->
> [!IMPORTANT]
> This project is connected to [Lovable](https://lovable.dev). Avoid rewriting
> published git history — force pushing, or rebasing/amending/squashing commits
> that are already pushed — as it rewrites history on Lovable's side and the
> user will likely lose their project history.
>
> Commits you push to the connected branch sync back to Lovable and show up in
> the editor, so keep the branch in a working state.
<!-- LOVABLE:END -->

- Public booking and availability go only through security-definer RPCs, including get_schedule and book_cycles — keeps customer data private and serializes capacity checks with an advisory lock per date.
- Cycle dates are explicitly published and edited through the admin schedule_days editor; never manufacture public availability from legacy time_slots, so administrator-defined capacity stays authoritative.
- Admin access = `admin` row in user_roles; the first account to open /admin claims it via claim_first_admin — bootstrap without manual DB edits.
