-- Inclusionary_ClientMatterUsers_Security
SELECT
    u.useremail	AS username, u.id AS user_id
FROM UsersForClientMatterSecurity u
WHERE EXISTS(SELECT 1 FROM ClientMatterSecurity cms WHERE cms.user_id = u.id)

UNION ALL
SELECT u.useremail, b.Id
FROM UsersForClientMatterSecurity u
         CROSS JOIN (
    SELECT publicentityuser_id AS id FROM SpecialUsersForClientMatterSecurity
    UNION ALL
    SELECT blankentityuser_id FROM SpecialUsersForClientMatterSecurity
) b
WHERE u.isadmin = 0

UNION ALL
SELECT u.useremail, b.publicsecuredentityuser_id
FROM UsersForClientMatterSecurity u
         CROSS JOIN SpecialUsersForClientMatterSecurity b
WHERE u.isadmin = 0
  AND NOT EXISTS(SELECT 1 FROM ExcludedUsersForClientMatterSecurity eu WHERE eu.user_id = u.id)
  AND NOT EXISTS(SELECT 1 FROM ClientMatterSecurity cms WHERE cms.user_id = u.id)

UNION ALL
SELECT u.useremail, b.id
FROM UsersForClientMatterSecurity u
         CROSS JOIN (
    SELECT adminuser_id AS id FROM SpecialUsersForClientMatterSecurity
    UNION ALL
    SELECT blankentityuser_id FROM SpecialUsersForClientMatterSecurity
) b
WHERE u.isadmin = 1
-- Inclusionary_TermClientMatterUsers_Security

SELECT DISTINCT s.[username], CASE WHEN t.EnforceClientMatterSecurityForInheritedTerms = 'false' THEN u.[adminuser_id] ELSE s.[user_id] END AS user_id
FROM Inclusionary_ClientMatterUsers_Security s
         CROSS JOIN SpecialUsersForClientMatterSecurity u
         CROSS JOIN (SELECT LOWER(EnforceClientMatterSecurityForInheritedTerms) AS EnforceClientMatterSecurityForInheritedTerms FROM SisenseConfigs LIMIT 1) t