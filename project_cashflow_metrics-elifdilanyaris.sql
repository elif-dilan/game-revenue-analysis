with base_table as (

	select
		gp.user_id,
		gpu.language,
		gpu.age,

		date_trunc('month', gp.payment_date::date) as monthly,
		sum(gp.revenue_amount_usd) as total_revenue

	from games_payments gp
	left join games_paid_users gpu
		on gp.user_id = gpu.user_id

	group by
		gp.user_id,
		gpu.language,
		gpu.age,
		date_trunc('month', gp.payment_date::date)
),

-- MONTHLY AGGREGATION
monthly_metrics as (

	select
		monthly,
		language,
		age,

		sum(total_revenue) as mrr,
		count(distinct user_id) as paid_users

	from base_table

	group by
		monthly,
		language,
		age
),

-- prev month metrics
monthly_with_prev as (

	select
		*,

		lag(mrr) over (
			partition by language, age
			order by monthly
		) as prev_mrr,

		lag(paid_users) over (
			partition by language, age
			order by monthly
		) as prev_paid_users

	from monthly_metrics
),

-- new users
new_metrics as (

	select
		monthly,
		language,
		age,

		count(distinct user_id) filter (
			where min_month = monthly
		) as new_paid_users,

		sum(total_revenue) filter (
			where min_month = monthly
		) as new_mrr

	from (

		select
			*,
			min(monthly) over (partition by user_id) as min_month
		from base_table

	) t

	group by
		monthly,
		language,
		age
),

-- churn
churn_metrics as (

	select
		monthly + interval '1 month' as churned_month,
		language,
		age,
		count(distinct user_id) as churned_users,
		sum(total_revenue) as churned_revenue

	from (

		select
			*,
			lead(monthly) over (
				partition by user_id
				order by monthly
			) as next_month
		from base_table

	) t

	where next_month is null
	   or next_month > monthly + interval '1 month'

	group by
		monthly,
		language,
		age
),

-- expansion / contraction
expansion_contraction as (

	select
		monthly,
		language,
		age,

		sum(
			case
				when diff > 0 then diff
			end
		) as expansion_mrr,

		sum(
			case
				when diff < 0 then abs(diff)
			end
		) as contraction_mrr

	from (

		select
			*,
			total_revenue - lag(total_revenue) over (
				partition by user_id
				order by monthly
			) as diff
		from base_table

	) t

	group by
		monthly,
		language,
		age
),

-- lifetime
user_lifetime as (

	select
		user_id,
		language,
		age,
		sum(total_revenue) as lifetime_revenue,
		count(distinct monthly) as lifetime_months

	from base_table

	group by
		user_id,
		language,
		age
),

ltv_metrics as (

	select
		language,
		age,
		avg(lifetime_revenue) as avg_ltv,
		avg(lifetime_months) as avg_lifetime
	from user_lifetime
	group by language, age
)

-- FINAL OUTPUT
select
	m.monthly,
	m.language,
	m.age,

	m.mrr,
	m.paid_users,

	m.mrr / nullif(m.paid_users,0) as arppu,

	n.new_paid_users,
	n.new_mrr,

	c.churned_users,
	c.churned_revenue,

	c.churned_users::float / nullif(m.prev_paid_users,0) as churn_rate,
	c.churned_revenue::float / nullif(m.prev_mrr,0) as revenue_churn_rate,

	e.expansion_mrr,
	e.contraction_mrr,

	l.avg_ltv,
	l.avg_lifetime

from monthly_with_prev m

left join new_metrics n
	on m.monthly = n.monthly
	and m.language = n.language
	and m.age = n.age

left join churn_metrics c
	on m.monthly = c.churned_month
	and m.language = c.language
	and m.age = c.age

left join expansion_contraction e
	on m.monthly = e.monthly
	and m.language = e.language
	and m.age = e.age

left join ltv_metrics l
	on m.language = l.language
	and m.age = l.age

order by m.monthly, m.language, m.age;